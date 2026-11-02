defmodule Nous.Eval.Guard.Dataset do
  @moduledoc """
  A set of `nous.guard_case/1` cases (`Nous.Eval.Guard.Case`) loaded from
  JSONL, with its manifest and content hash.

      {:ok, ds} = Nous.Eval.Guard.Dataset.load("test/fixtures/guard")
      :ok = Nous.Eval.Guard.Dataset.validate(ds, licences: :in_repo, pii: true)

  `load/2` takes a `.jsonl` file or a directory (every `*.jsonl` directly in
  it). A directory with a `*.manifest.json` (schema `nous.guard_dataset/1`)
  is checked against it: the listed files must be exactly the JSONL files
  present, and each file's canonical hash (`Nous.Eval.Guard.Hygiene.sha256/1`)
  must match. Loading fails closed on the first error: a malformed line, an
  unknown key, a duplicate id or a manifest mismatch.

  ## Manifest

  ```json
  {"schema": "nous.guard_dataset/1", "name": "nous-builtin-guard", "version": "2026.11.0",
   "case_schema": "nous.guard_case/1",
   "files": [{"path": "user_input.jsonl", "sha256": "sha256:...", "cases": 640}],
   "counts": {"user_input": {"tune": {"block": 120, "allow": 180}}},
   "split_seed": "nous-guard-v1",
   "sources": [{"id": "deepset/prompt-injections", "revision": "4f61ecb0...", "license": "Apache-2.0"}],
   "accepted_terms": []}
  ```

  `write/3` writes a dataset in this layout (one canonical JSONL file per
  surface, plus one per deterministic kind) with its manifest.
  """

  alias Nous.Eval.CanonicalJSON
  alias Nous.Eval.Guard.{Case, Hygiene}

  @manifest_schema "nous.guard_dataset/1"

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: String.t() | nil,
          cases: [Case.t()],
          hash: String.t(),
          manifest: map() | nil,
          source: Path.t() | nil
        }

  @enforce_keys [:hash]
  defstruct [:name, :version, :hash, :manifest, :source, cases: []]

  @doc "The manifest schema id (`\"nous.guard_dataset/1\"`)."
  @spec manifest_schema() :: String.t()
  def manifest_schema, do: @manifest_schema

  @doc """
  A dataset from cases already built in Elixir. Ids must be unique.

  Options: `:name`, `:version`.
  """
  @spec new([Case.t()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(cases, opts \\ []) when is_list(cases) do
    with :ok <- unique_ids(cases) do
      {:ok,
       %__MODULE__{
         name: Keyword.get(opts, :name),
         version: Keyword.get(opts, :version),
         cases: Enum.sort_by(cases, & &1.id),
         hash: Hygiene.sha256(cases)
       }}
    end
  end

  @doc """
  Loads a JSONL file or a directory of them (see the moduledoc).

  Options: `:verify_manifest` (default `true`; a directory without a
  manifest loads unverified either way).
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(path, opts \\ []) when is_binary(path) do
    cond do
      File.dir?(path) -> load_dir(path, Keyword.get(opts, :verify_manifest, true))
      File.regular?(path) -> load_files([path], nil, path)
      true -> {:error, "#{path}: no such file or directory"}
    end
  end

  defp load_dir(dir, verify?) do
    files = dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.sort()

    with {:ok, manifest} <- read_manifest(dir),
         {:ok, by_file} <- parse_files(files),
         :ok <- if(verify? and manifest, do: verify(manifest, by_file, dir), else: :ok) do
      build(Enum.flat_map(by_file, &elem(&1, 1)), manifest, dir)
    end
  end

  defp load_files(files, manifest, source) do
    with {:ok, by_file} <- parse_files(files) do
      build(Enum.flat_map(by_file, &elem(&1, 1)), manifest, source)
    end
  end

  defp build(cases, manifest, source) do
    with :ok <- unique_ids(cases) do
      {:ok,
       %__MODULE__{
         name: manifest && manifest["name"],
         version: manifest && manifest["version"],
         cases: Enum.sort_by(cases, & &1.id),
         hash: Hygiene.sha256(cases),
         manifest: manifest,
         source: source
       }}
    end
  end

  defp read_manifest(dir) do
    case Path.wildcard(Path.join(dir, "*.manifest.json")) do
      [] ->
        {:ok, nil}

      [path] ->
        with {:ok, body} <- File.read(path),
             {:ok, %{"schema" => @manifest_schema, "files" => files} = manifest}
             when is_list(files) <- JSON.decode(body) do
          {:ok, manifest}
        else
          {:ok, other} ->
            {:error, "#{path}: not a #{@manifest_schema} manifest: #{inspect(other)}"}

          {:error, reason} ->
            {:error, "#{path}: #{inspect(reason)}"}
        end

      several ->
        {:error, "#{dir}: more than one manifest: #{inspect(several)}"}
    end
  end

  defp parse_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case parse_file(file) do
        {:ok, cases} -> {:cont, {:ok, acc ++ [{Path.basename(file), cases}]}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Parses one JSONL file of guard cases. Blank lines are skipped; errors name
  the file and line.
  """
  @spec parse_file(Path.t()) :: {:ok, [Case.t()]} | {:error, String.t()}
  def parse_file(path) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, n}, {:ok, acc} ->
      if String.trim(line) == "" do
        {:cont, {:ok, acc}}
      else
        with {:ok, map} <- decode_line(line),
             {:ok, c} <- Case.from_map(map) do
          {:cont, {:ok, [c | acc]}}
        else
          {:error, message} -> {:halt, {:error, "#{path}:#{n}: #{message}"}}
        end
      end
    end)
    |> case do
      {:ok, cases} -> {:ok, Enum.reverse(cases)}
      error -> error
    end
  rescue
    e in File.Error -> {:error, Exception.message(e)}
  end

  defp decode_line(line) do
    case JSON.decode(line) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  defp verify(manifest, by_file, dir) do
    listed = Map.new(manifest["files"], &{&1["path"], &1})
    present = Map.new(by_file)

    cond do
      Enum.sort(Map.keys(listed)) != Enum.sort(Map.keys(present)) ->
        {:error,
         "#{dir}: manifest lists #{inspect(Enum.sort(Map.keys(listed)))}, " <>
           "found #{inspect(Enum.sort(Map.keys(present)))}"}

      bad =
          Enum.find(present, fn {file, cases} ->
            Hygiene.sha256(cases) != listed[file]["sha256"]
          end) ->
        {file, cases} = bad

        {:error,
         "#{dir}/#{file}: sha256 #{Hygiene.sha256(cases)} does not match the manifest's " <>
           inspect(listed[file]["sha256"])}

      true ->
        :ok
    end
  end

  defp unique_ids(cases) do
    case cases |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] ->
        :ok

      dups ->
        {:error, "duplicate case ids: #{inspect(dups |> Enum.map(&elem(&1, 0)) |> Enum.sort())}"}
    end
  end

  # ── selection ─────────────────────────────────────────────────────────────

  @doc """
  The cases matching every given filter: `:kind`, `:surface`, `:split`,
  `:label` (each one value or a list), `:labelled` (`true` drops `label:
  null`), `:certifiable` (`true` keeps `Nous.Eval.Guard.Case.certifiable?/1`
  cases).
  """
  @spec cases(t(), keyword()) :: [Case.t()]
  def cases(%__MODULE__{cases: cases}, filters \\ []) do
    Enum.filter(cases, fn c ->
      Enum.all?(filters, fn
        {:kind, v} -> c.kind in List.wrap(v)
        {:surface, v} -> c.surface in List.wrap(v)
        {:split, v} -> c.split in List.wrap(v)
        {:label, v} -> c.label in List.wrap(v)
        {:labelled, true} -> c.label != nil
        {:certifiable, true} -> Case.certifiable?(c)
        {_key, _any} -> true
      end)
    end)
  end

  # ── validation ────────────────────────────────────────────────────────────

  @doc """
  Checks the dataset invariants and returns every problem found.

  Always: unique ids; no exact duplicate (`Nous.Eval.Guard.Hygiene.dedup_key/1`)
  within a surface; no group in two splits; every split of a surface holds
  both labels (labelled classifier cases).

  Options:

    * `:licences` - `:in_repo` or `:fetch` (`Nous.Eval.Guard.Hygiene.licence_violations/2`);
      default none, so an app can load data of any licence for itself
    * `:pii` - `true` runs `Nous.Eval.Guard.Hygiene.pii_lint/1`
    * `:near_duplicates` - `true` also refuses near-duplicate pairs that
      cross splits (O(n²) per surface up to the MinHash threshold)
  """
  @spec validate(t(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{cases: cases}, opts \\ []) do
    classifier = Enum.filter(cases, &(&1.kind == :classifier))

    problems =
      Enum.concat([
        ids_problems(cases),
        duplicate_problems(classifier),
        group_problems(classifier),
        label_problems(classifier),
        licence_problems(cases, Keyword.get(opts, :licences)),
        pii_problems(cases, Keyword.get(opts, :pii, false)),
        near_problems(classifier, Keyword.get(opts, :near_duplicates, false))
      ])

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp ids_problems(cases) do
    case unique_ids(cases) do
      :ok -> []
      {:error, message} -> [message]
    end
  end

  defp duplicate_problems(classifier) do
    classifier
    |> Enum.group_by(&{&1.surface, Hygiene.dedup_key(Hygiene.canonical_text(&1))}, & &1.id)
    |> Enum.filter(fn {_key, ids} -> length(ids) > 1 end)
    |> Enum.map(fn {_key, ids} -> "exact duplicates: #{inspect(Enum.sort(ids))}" end)
    |> Enum.sort()
  end

  defp group_problems(classifier) do
    classifier
    |> Enum.group_by(& &1.group, & &1.split)
    |> Enum.filter(fn {_group, splits} -> length(Enum.uniq(splits)) > 1 end)
    |> Enum.map(fn {group, splits} ->
      "group #{inspect(group)} spans splits #{inspect(splits |> Enum.uniq() |> Enum.sort())}"
    end)
    |> Enum.sort()
  end

  defp label_problems(classifier) do
    classifier
    |> Enum.filter(& &1.label)
    |> Enum.group_by(&{&1.surface, &1.split}, & &1.label)
    |> Enum.flat_map(fn {{surface, split}, labels} ->
      case [:block, :allow] -- labels do
        [] ->
          []

        missing ->
          ["#{surface}/#{split} has no #{Enum.map_join(missing, ", ", &Atom.to_string/1)} case"]
      end
    end)
    |> Enum.sort()
  end

  defp licence_problems(_cases, nil), do: []

  defp licence_problems(cases, policy) do
    for {id, license} <- Hygiene.licence_violations(cases, policy),
        do: "case #{inspect(id)}: licence #{inspect(license)} is not allowed (#{policy})"
  end

  defp pii_problems(_cases, false), do: []

  defp pii_problems(cases, true) do
    for %{id: id, kind: kind, value: value} <- Hygiene.pii_lint(cases),
        do:
          "case #{inspect(id)}: #{kind} #{inspect(value)} (tag synthetic_pii with reserved values)"
  end

  defp near_problems(_classifier, false), do: []

  defp near_problems(classifier, true) do
    split = Map.new(classifier, &{&1.id, &1.split})

    for {a, b, j} <- Hygiene.near_duplicates(classifier),
        split[a] != split[b],
        do:
          "near duplicates across splits: #{inspect(a)} (#{split[a]}) ~ #{inspect(b)} " <>
            "(#{split[b]}), jaccard #{Float.round(j, 3)}"
  end

  # ── writing ───────────────────────────────────────────────────────────────

  @doc """
  The manifest for `cases` written as `files` (`[{path, cases}]`).

  Options: `:name`, `:version`, `:split_seed`, `:sources` (list of maps),
  `:accepted_terms` (list of source ids).
  """
  @spec manifest([{String.t(), [Case.t()]}], keyword()) :: map()
  def manifest(files, opts \\ []) do
    all = Enum.flat_map(files, &elem(&1, 1))

    %{
      "schema" => @manifest_schema,
      "name" => Keyword.get(opts, :name),
      "version" => Keyword.get(opts, :version),
      "case_schema" => Case.schema(),
      "files" =>
        files
        |> Enum.sort()
        |> Enum.map(fn {path, cases} ->
          %{"path" => path, "sha256" => Hygiene.sha256(cases), "cases" => length(cases)}
        end),
      "counts" => counts(all),
      "split_seed" => Keyword.get(opts, :split_seed),
      "sources" => Keyword.get(opts, :sources, []),
      "accepted_terms" => Keyword.get(opts, :accepted_terms, [])
    }
  end

  defp counts(cases) do
    cases
    |> Enum.filter(&(&1.kind == :classifier))
    |> Enum.group_by(&Atom.to_string(&1.surface))
    |> Map.new(fn {surface, members} ->
      {surface,
       members
       |> Enum.group_by(&Atom.to_string(&1.split))
       |> Map.new(fn {split, ms} ->
         {split, Enum.frequencies_by(ms, &((&1.label && Atom.to_string(&1.label)) || "null"))}
       end)}
    end)
  end

  @doc """
  Writes `cases` to `dir` as canonical JSONL (`<surface>.jsonl` per surface,
  `<kind>.jsonl` per deterministic kind) plus `<name>.manifest.json`.
  Returns the manifest. Options as `manifest/2`; `:name` is required.
  """
  @spec write([Case.t()], Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(cases, dir, opts) do
    name = Keyword.fetch!(opts, :name)

    files =
      cases
      |> Enum.group_by(fn c -> Atom.to_string(c.surface || c.kind) <> ".jsonl" end)
      |> Enum.sort()

    manifest = manifest(files, opts)

    with :ok <- unique_ids(cases),
         :ok <- File.mkdir_p(dir),
         :ok <- write_all(dir, files),
         :ok <-
           File.write(
             Path.join(dir, name <> ".manifest.json"),
             CanonicalJSON.encode(manifest) <> "\n"
           ) do
      {:ok, manifest}
    end
  end

  defp write_all(dir, files) do
    Enum.reduce_while(files, :ok, fn {path, cases}, :ok ->
      case File.write(Path.join(dir, path), Hygiene.canonical_jsonl(cases)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
