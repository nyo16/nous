defmodule Nous.Eval.Guard.Fetch do
  @moduledoc """
  Downloads a registered guard dataset (`Nous.Eval.Guard.Registry`), checks
  it and writes it as `nous.guard_case/1` JSONL. `mix
  nous.eval.datasets.fetch` is the command-line front end.

  Every step fails closed:

    1. **Resolve** the source against the compiled registry (string ids;
       nothing becomes an atom). `id@rev` is accepted for the pinned
       revision only.
    2. **Licence gate.** `:denied` sources are refused with the reason.
       `:terms` sources need `accept_terms: [id]` and the acceptance is
       recorded in the manifest. A gated Hugging Face source needs a token
       (`:hf_token_env`); Nous cannot accept a gate for you.
    3. **Download** only the registry's pinned URLs, each capped at its
       registered `:max_bytes` (cached by sha256 under
       `:filename.basedir(:user_cache, "nous")/eval/downloads`), and
       **verify the sha256 before parsing**: a mismatch deletes nothing of
       yours, keeps nothing it downloaded and is an error.
    4. **Parse** CSV / JSON / JSONL natively; parquet only with the optional
       `:duckdbex` dependency.
    5. **Adapt** rows to cases with the registry's adapter (literal label
       tables, provenance with revision and row).
    6. **Hygiene** (`Nous.Eval.Guard.Hygiene`): exact dedup (conflicting
       labels are an error), near-duplicate grouping, group-hash splits, the
       licence policy. PII findings are counted in the result (the in-repo
       validator is the gate for committed data).
    7. **Sample** (`:sample`), deterministically: per surface and label, the
       cases with the smallest `sha256(seed <> ":" <> id)`, in proportion.
    8. **Write** to `:out` (default the cache's `eval/datasets/<id>@<rev>`):
       one JSONL file per surface, a `nous.guard_dataset/1` manifest with
       file hashes, and a `NOTICE`.

  Options: `:accept_terms` (list of source ids), `:hf_token_env` (default
  `"HF_TOKEN"`), `:cache_dir`, `:out`, `:sample`, `:seed` (default
  `"nous-guard-v1"`), `:fractions` (split shares, default
  `Nous.Eval.Guard.Hygiene`'s), `:sources` (the registry to resolve against,
  default `Nous.Eval.Guard.Registry.sources/0`) and `:http` - `(url, headers,
  max_bytes -> {:ok, body} | {:error, reason})`, default a streaming `Req`
  GET that aborts with `{:error, {:too_large, max_bytes}}` once the body
  passes the file's registered `:max_bytes`. Only the resolved source's file
  URLs are ever passed to it, and a body over `max_bytes` is refused before
  it is hashed even if the function returns one.
  """

  alias Nous.Eval.Guard.{Case, Dataset, Hygiene, Registry}

  @default_seed "nous-guard-v1"

  @type result :: %{
          source: String.t(),
          out: Path.t(),
          manifest: map(),
          cases: non_neg_integer(),
          pii_findings: non_neg_integer()
        }

  @doc "Fetches `spec` (see the moduledoc). Returns `{:error, message}` on any failure."
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def run(spec, opts \\ []) do
    with {:ok, source} <- Registry.fetch(spec, Keyword.get(opts, :sources, Registry.sources())),
         :ok <- licence_gate(source, opts),
         {:ok, headers} <- auth(source, opts),
         {:ok, rows} <- download_all(source, headers, opts),
         {:ok, cases} <- adapt(source, rows),
         {:ok, cases} <- hygiene(source, cases, opts),
         :ok <- licences(source, cases),
         cases = sample(cases, opts),
         {:ok, out, manifest} <- write(source, cases, opts) do
      {:ok,
       %{
         source: source.id,
         out: out,
         manifest: manifest,
         cases: length(cases),
         pii_findings: length(Hygiene.pii_lint(cases))
       }}
    end
  end

  @doc "The default cache root: `:filename.basedir(:user_cache, \"nous\")`."
  @spec cache_dir() :: Path.t()
  def cache_dir, do: to_string(:filename.basedir(:user_cache, "nous"))

  defp licence_gate(%{status: :denied} = s, _opts),
    do: {:error, "#{s.id} is not fetched: #{s.license}: #{s.reason}"}

  defp licence_gate(%{status: :terms} = s, opts) do
    if s.id in Keyword.get(opts, :accept_terms, []),
      do: :ok,
      else:
        {:error,
         "#{s.id} (#{s.license}) is use-restricted: #{s.reason}. Pass --accept-terms #{s.id} to accept " <>
           "these terms; the acceptance is recorded in the manifest"}
  end

  defp licence_gate(%{status: :allowed}, _opts), do: :ok

  defp auth(source, opts) do
    var = Keyword.get(opts, :hf_token_env, "HF_TOKEN")

    case {source.gated, System.get_env(var)} do
      {false, _} ->
        {:ok, []}

      {true, token} when is_binary(token) and token != "" ->
        {:ok, [{"authorization", "Bearer " <> token}]}

      {true, _} ->
        {:error,
         "#{source.id} is gated on Hugging Face: accept its terms on #{source.homepage} and set #{var}"}
    end
  end

  # ── download ──────────────────────────────────────────────────────────────

  defp download_all(source, headers, opts) do
    Enum.reduce_while(source.files, {:ok, []}, fn file, {:ok, acc} ->
      with :ok <- check_cap(file),
           {:ok, body} <- download(file, headers, opts),
           {:ok, rows} <- parse(file, body) do
        {:cont, {:ok, acc ++ [{file, rows}]}}
      else
        {:error, message} -> {:halt, {:error, "#{source.id}: #{file.name}: #{message}"}}
      end
    end)
  end

  # Fail closed: a file without a positive integer cap is never downloaded.
  defp check_cap(%{max_bytes: max}) when is_integer(max) and max > 0, do: :ok

  defp check_cap(file),
    do:
      {:error, "max_bytes must be a positive integer, got #{inspect(Map.get(file, :max_bytes))}"}

  defp download(file, headers, opts) do
    path =
      Path.join([Keyword.get(opts, :cache_dir, cache_dir()), "eval", "downloads", file.sha256])

    case File.read(path) do
      {:ok, body} ->
        # A cached file is re-verified: the cache is not trusted either.
        if sha256(body) == file.sha256,
          do: {:ok, body},
          else: fetch_verified(file, headers, path, opts)

      {:error, _} ->
        fetch_verified(file, headers, path, opts)
    end
  end

  defp fetch_verified(file, headers, path, opts) do
    http = Keyword.get(opts, :http, &http_get/3)

    case http.(file.url, headers, file.max_bytes) do
      {:ok, body} when is_binary(body) and byte_size(body) > file.max_bytes ->
        too_large(file)

      {:error, {:too_large, _}} ->
        too_large(file)

      {:ok, body} when is_binary(body) ->
        actual = sha256(body)

        if actual == file.sha256 do
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          {:ok, body}
        else
          File.rm(path)

          {:error,
           "sha256 mismatch for #{file.url}: expected #{file.sha256}, got #{actual}; refused before parsing"}
        end

      {:ok, other} ->
        {:error, "unexpected response body #{inspect(other, limit: 5)}"}

      {:error, reason} ->
        {:error, "download of #{file.url} failed: #{inspect(reason)}"}
    end
  end

  defp too_large(file),
    do: {:error, "download of #{file.url} refused: larger than #{file.max_bytes} bytes"}

  defp http_get(url, headers, max_bytes) do
    # Streamed so an oversized body is aborted once it passes `max_bytes`
    # instead of being buffered whole.
    into = fn {:data, data}, {req, resp} ->
      size = Req.Response.get_private(resp, :nous_bytes, 0) + byte_size(data)
      resp = Req.Response.put_private(resp, :nous_bytes, size)

      if size > max_bytes do
        {:halt, {req, Req.Response.put_private(resp, :nous_too_large, true)}}
      else
        {:cont, {req, %{resp | body: [resp.body, data]}}}
      end
    end

    case Req.get(url,
           headers: headers,
           decode_body: false,
           retry: false,
           receive_timeout: 120_000,
           into: into
         ) do
      {:ok, %Req.Response{} = resp} ->
        cond do
          Req.Response.get_private(resp, :nous_too_large, false) ->
            {:error, {:too_large, max_bytes}}

          resp.status == 200 ->
            {:ok, IO.iodata_to_binary(resp.body)}

          true ->
            {:error, {:http_status, resp.status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha256(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  # ── parsing ───────────────────────────────────────────────────────────────

  defp parse(%{format: :csv}, body), do: Nous.Eval.Guard.CSV.parse(body)

  defp parse(%{format: :json}, body) do
    case JSON.decode(body) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, %{"behaviors" => rows}} when is_list(rows) -> {:ok, rows}
      {:ok, other} -> {:error, "expected a JSON array of rows, got #{inspect(other, limit: 3)}"}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  defp parse(%{format: format}, body) when format in [:jsonl, :guard_jsonl] do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case JSON.decode(line) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, "invalid JSONL line: #{inspect(reason)}"}}
      end
    end)
    |> then(fn
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end)
  end

  defp parse(%{format: :parquet}, body) do
    if Code.ensure_loaded?(Nous.Eval.Guard.Parquet),
      do: Nous.Eval.Guard.Parquet.rows(body),
      else:
        {:error,
         "parquet sources need the optional dependency: add {:duckdbex, \"~> 0.3\"} to your deps"}
  end

  # ── cases ─────────────────────────────────────────────────────────────────

  defp adapt(%{adapter: nil}, files) do
    files
    |> Enum.flat_map(fn {_file, rows} -> rows end)
    |> from_maps()
  end

  defp adapt(%{adapter: adapter}, files) do
    files
    |> Enum.flat_map(fn {file, rows} ->
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, index} ->
        case adapter.(file, row, index) do
          {:ok, map} -> [Map.put(map, "split", "tune")]
          :skip -> []
        end
      end)
    end)
    |> from_maps()
    |> case do
      # The adapter's provisional split only lets the case parse; the real
      # one is assigned by group below.
      {:ok, cases} -> {:ok, Enum.map(cases, &%{&1 | split: nil})}
      error -> error
    end
  end

  defp from_maps(maps) do
    Enum.reduce_while(maps, {:ok, []}, fn map, {:ok, acc} ->
      case Case.from_map(map) do
        {:ok, c} -> {:cont, {:ok, [c | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> then(fn
      {:ok, cases} -> {:ok, Enum.reverse(cases)}
      error -> error
    end)
  end

  # The built-in dataset arrives already deduplicated, grouped and split.
  defp hygiene(%{adapter: nil}, cases, _opts), do: {:ok, cases}

  defp hygiene(_source, cases, opts) do
    split_opts =
      [seed: Keyword.get(opts, :seed, @default_seed)] ++ Keyword.take(opts, [:fractions])

    with {:ok, cases} <- dedup(cases),
         grouped = Hygiene.group(cases),
         {:ok, split} <- assign(grouped, split_opts) do
      {:ok, split}
    end
  end

  defp dedup(cases) do
    case Hygiene.dedup(cases) do
      {:ok, cases} ->
        {:ok, cases}

      {:error, conflicts} ->
        {:error, "exact duplicates with different labels (label noise): #{inspect(conflicts)}"}
    end
  end

  defp assign(cases, opts) do
    case Hygiene.assign_splits(cases, opts) do
      {:ok, cases} -> {:ok, cases}
      {:error, reason} -> {:error, "split assignment failed: #{inspect(reason)}"}
    end
  end

  defp licences(source, cases) do
    case Hygiene.licence_violations(cases, :fetch) do
      [] ->
        :ok

      bad ->
        {:error,
         "#{source.id}: cases with a licence the fetch policy refuses: #{inspect(Enum.take(bad, 5))}"}
    end
  end

  @doc false
  # Deterministic proportional sample per surface and label.
  @spec sample([Case.t()], keyword()) :: [Case.t()]
  def sample(cases, opts) do
    case Keyword.get(opts, :sample) do
      nil ->
        cases

      n when is_integer(n) and n >= length(cases) ->
        cases

      n when is_integer(n) and n > 0 ->
        seed = Keyword.get(opts, :seed, @default_seed)
        total = length(cases)

        cases
        |> Enum.group_by(&{&1.surface, &1.label})
        |> Enum.sort()
        |> Enum.flat_map(fn {_stratum, members} ->
          take = max(round(n * length(members) / total), 1)
          members |> Enum.sort_by(&sha256(seed <> ":" <> &1.id)) |> Enum.take(take)
        end)
        |> Enum.sort_by(& &1.id)
    end
  end

  # ── writing ───────────────────────────────────────────────────────────────

  defp write(source, cases, opts) do
    name = safe_name(source.id)

    out =
      Keyword.get(opts, :out) ||
        Path.join([
          Keyword.get(opts, :cache_dir, cache_dir()),
          "eval",
          "datasets",
          "#{name}@#{source.revision}"
        ])

    accepted = if source.status == :terms, do: [source.id], else: []

    manifest_opts = [
      name: name,
      version: source.revision,
      split_seed: Keyword.get(opts, :seed, @default_seed),
      sources: [
        %{
          "id" => source.id,
          "revision" => source.revision,
          "license" => source.license,
          "url" => source.homepage
        }
      ],
      accepted_terms: accepted
    ]

    with {:ok, manifest} <- Dataset.write(cases, out, manifest_opts),
         :ok <- File.write(Path.join(out, "NOTICE"), notice(source)) do
      {:ok, out, manifest}
    else
      {:error, reason} -> {:error, "could not write #{out}: #{inspect(reason)}"}
    end
  end

  defp safe_name(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]+/, "_")

  defp notice(source) do
    """
    #{source.title}
    Source: #{source.homepage} (revision #{source.revision})
    Licence: #{source.license}#{if source.license_url, do: " (" <> source.license_url <> ")", else: ""}
    Attribution: #{source.attribution}
    Modified: sampled and reformatted into nous.guard_case/1 by mix nous.eval.datasets.fetch.
    #{if source.reason, do: "Terms: " <> source.reason <> "\n", else: ""}\
    """
  end
end
