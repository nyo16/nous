defmodule Nous.Eval.Guard.Hygiene do
  @moduledoc """
  Dataset hygiene for guard cases (`Nous.Eval.Guard.Case`): exact and
  near-duplicate detection, leakage-free group splits, licence policy, a PII
  lint and canonical JSONL hashing.

  ## Canonical text and exact duplicates

  `canonical_text/1` is the text a duplicate check compares, per surface:
  `user_input` the text (plus attached documents), `tool_result` the result
  (canonical JSON when structured), `tool_call` the canonical JSON of
  `{tool name, arguments}`, `model_output` the content plus canonical
  `tool_calls`. `dedup_key/1` hashes it after NFKC, lower-casing and
  whitespace collapsing. The normalisation is for comparison only: stored
  text stays byte-exact, because homoglyph and zero-width payloads are the
  test. `dedup/1` keeps the lowest id of each key (the others are listed in
  its `provenance.duplicates`) and refuses a key whose cases disagree on the
  label.

  ## Near duplicates and groups

  Two cases are near duplicates when the Jaccard similarity of their
  5-shingle sets is at least `0.5`: word 5-grams, or character 5-grams for a
  text under 8 words (word shingles degenerate on short prompts). Up to
  `:minhash_above` cases per surface (default 5,000) every pair is compared;
  above it a MinHash index (128 hashes in 32 bands of 4) proposes candidate
  pairs and each is verified exactly. Near duplicates are kept, not deleted:
  `group/2` joins them into one group (connected components over
  near-duplicate edges, a shared `provenance.template_id`, a
  `provenance.derived_from` link and a shared declared `group`), so they stay
  as robustness signal without inflating n or leaking across splits.

  ## Splits

  `assign_splits/2` gives every group one split. A group whose members
  already declare one keeps it (two different declared splits are an
  error); any other group is placed by `sha256(seed <> ":" <> group)`, so
  adding cases never moves an existing group.

  ## Licences

  | Status | Licences |
  |---|---|
  | `:in_repo` | MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, CC0-1.0, CC-BY-4.0 |
  | `:terms` (fetch only, `--accept-terms`) | ODC-BY-1.0, CC-BY-SA-4.0, `LicenseRef-MIT-use-restricted` |
  | `:denied` | anything else (NC, AGPL, no licence, private) |

  ## PII lint

  `pii_lint/1` flags e-mail addresses, phone numbers, Luhn-valid card
  numbers, IBANs and secret-shaped strings (`sk-…`, `AKIA…`, JWTs) anywhere
  in a case's input. A hit is allowed only on a case tagged `synthetic_pii`,
  and for e-mail addresses and phone numbers only with reserved values
  (`example.com`/`.net`/`.org`, `.example`, `.invalid`, `.test`,
  `.localhost` domains; `555-01xx` numbers). It is a maintainer lint over
  fixtures, not a runtime redactor.
  """

  alias Nous.Eval.CanonicalJSON
  alias Nous.Eval.Guard.Case

  @in_repo ~w(MIT Apache-2.0 BSD-2-Clause BSD-3-Clause CC0-1.0 CC-BY-4.0)
  @terms ~w(ODC-BY-1.0 CC-BY-SA-4.0 LicenseRef-MIT-use-restricted)

  @default_threshold 0.5
  @default_minhash_above 5_000
  @minhash_bands 32
  @minhash_rows 4

  @default_split_seed "nous-guard-v1"
  @default_fractions [tune: 0.4, holdout: 0.3, test: 0.3]
  @split_names %{tune: "tune", holdout: "holdout", test: "test"}

  @reserved_domains ~w(example.com example.net example.org)
  @reserved_tlds ~w(.example .invalid .test .localhost)

  # ── canonical text and exact duplicates ──────────────────────────────────

  @doc "The text duplicate checks compare for a classifier case (see the moduledoc)."
  @spec canonical_text(Case.t()) :: String.t()
  def canonical_text(%Case{surface: :user_input, input: input}) do
    docs =
      input
      |> Map.get("attachments", [])
      |> Enum.map(fn a -> "[Document #{a["media_type"]}] " <> a["text"] end)

    Enum.join([input["text"] | docs], " ")
  end

  def canonical_text(%Case{surface: :tool_result, input: %{"result" => result}}) do
    if is_binary(result), do: result, else: CanonicalJSON.encode(result)
  end

  def canonical_text(%Case{surface: :tool_call, input: input}) do
    CanonicalJSON.encode(%{"name" => input["tool"]["name"], "arguments" => input["arguments"]})
  end

  def canonical_text(%Case{surface: :model_output, input: input}) do
    case input["tool_calls"] do
      [_ | _] = calls -> input["content"] <> "\n" <> CanonicalJSON.encode(calls)
      _ -> input["content"]
    end
  end

  def canonical_text(%Case{} = c), do: CanonicalJSON.encode(c.input)

  @doc """
  `"sha256:<hex>"` of `text` after NFKC, lower-casing and collapsing
  whitespace: equal keys are exact duplicates.
  """
  @spec dedup_key(String.t()) :: String.t()
  def dedup_key(text) when is_binary(text), do: CanonicalJSON.digest(normalize(text))

  @doc """
  Exact deduplication per surface (classifier cases only; others pass
  through). Of each key the lowest id is kept and the others are recorded in
  its `provenance.duplicates`.

  Returns `{:error, conflicts}` when cases sharing a key disagree on the
  label (label noise: send them to review, never pick one), with
  `conflicts :: [[id]]`.
  """
  @spec dedup([Case.t()]) :: {:ok, [Case.t()]} | {:error, [[String.t()]]}
  def dedup(cases) when is_list(cases) do
    {classifier, others} = Enum.split_with(cases, &(&1.kind == :classifier))

    groups =
      classifier
      |> Enum.group_by(&{&1.surface, dedup_key(canonical_text(&1))})
      |> Map.values()
      |> Enum.map(fn group -> Enum.sort_by(group, & &1.id) end)

    case Enum.filter(groups, &(length(Enum.uniq_by(&1, fn c -> c.label end)) > 1)) do
      [] ->
        kept =
          Enum.map(groups, fn
            [only] ->
              only

            [keep | dups] ->
              previous = Map.get(keep.provenance, "duplicates", [])
              ids = Enum.sort(Enum.uniq(previous ++ Enum.map(dups, & &1.id)))
              %{keep | provenance: Map.put(keep.provenance, "duplicates", ids)}
          end)

        {:ok, Enum.sort_by(kept ++ others, & &1.id)}

      conflicts ->
        {:error, Enum.map(conflicts, fn group -> Enum.map(group, & &1.id) end)}
    end
  end

  defp normalize(text) do
    text
    |> :unicode.characters_to_nfkc_binary()
    |> case do
      normalized when is_binary(normalized) -> normalized
      _invalid -> text
    end
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  # ── near duplicates ───────────────────────────────────────────────────────

  @doc """
  The 5-shingle set of `text` (hashed): word 5-grams, or character 5-grams
  when the text has fewer than 8 words. Normalised as `dedup_key/1`.
  """
  @spec shingles(String.t()) :: MapSet.t(non_neg_integer())
  def shingles(text) when is_binary(text) do
    normalized = normalize(text)
    words = String.split(normalized, " ", trim: true)

    grams =
      if length(words) >= 8,
        do: windows(words, 5),
        else: normalized |> String.graphemes() |> windows(5)

    MapSet.new(grams, &:erlang.phash2(&1, 4_294_967_296))
  end

  defp windows(items, n) when length(items) <= n, do: [items]
  defp windows(items, n), do: Enum.chunk_every(items, n, 1, :discard)

  @doc "Jaccard similarity of two shingle sets (`1.0` for two empty sets)."
  @spec jaccard(MapSet.t(), MapSet.t()) :: float()
  def jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 1.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end

  @doc """
  Near-duplicate pairs `{id_a, id_b, jaccard}` (`id_a < id_b`) among
  classifier cases of the same surface.

  Options: `:threshold` (default `0.5`), `:minhash_above` (default `5_000`
  cases per surface; above it candidates come from MinHash banding and are
  then verified exactly).
  """
  @spec near_duplicates([Case.t()], keyword()) :: [{String.t(), String.t(), float()}]
  def near_duplicates(cases, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    minhash_above = Keyword.get(opts, :minhash_above, @default_minhash_above)

    cases
    |> Enum.filter(&(&1.kind == :classifier))
    |> Enum.group_by(& &1.surface)
    |> Enum.flat_map(fn {_surface, members} ->
      items = Enum.map(members, &{&1.id, shingles(canonical_text(&1))})

      candidates =
        if length(items) > minhash_above,
          do: minhash_candidates(items),
          else: all_pairs(items)

      by_id = Map.new(items)

      for {a, b} <- candidates,
          j = jaccard(Map.fetch!(by_id, a), Map.fetch!(by_id, b)),
          j >= threshold,
          do: {a, b, j}
    end)
    |> Enum.sort()
  end

  defp all_pairs(items) do
    ids = items |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    ids
    |> Enum.with_index()
    |> Enum.flat_map(fn {a, i} -> ids |> Enum.drop(i + 1) |> Enum.map(&{a, &1}) end)
  end

  # MinHash with `bands * rows` hash functions (`phash2({i, shingle})`); two
  # items that agree on every row of some band are a candidate pair.
  defp minhash_candidates(items) do
    perms = @minhash_bands * @minhash_rows

    items
    |> Enum.flat_map(fn {id, set} ->
      signature =
        for i <- 0..(perms - 1) do
          if MapSet.size(set) == 0,
            do: 0,
            else: Enum.reduce(set, :infinity, &min(:erlang.phash2({i, &1}), &2))
        end

      signature
      |> Enum.chunk_every(@minhash_rows)
      |> Enum.with_index()
      |> Enum.map(fn {band, b} -> {{b, band}, id} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.values()
    |> Enum.flat_map(fn ids -> ids |> Enum.sort() |> pairs() end)
    |> Enum.uniq()
  end

  defp pairs([]), do: []
  defp pairs([a | rest]), do: Enum.map(rest, &{a, &1}) ++ pairs(rest)

  # ── groups ────────────────────────────────────────────────────────────────

  @doc """
  Assigns each classifier case the group of its connected component over
  near-duplicate edges (`near_duplicates/2`, same options), a shared
  `provenance.template_id`, `provenance.derived_from` links and a shared
  declared `group`. A component is named after the smallest declared group
  that is not a member's own id, else its smallest id.
  """
  @spec group([Case.t()], keyword()) :: [Case.t()]
  def group(cases, opts \\ []) do
    {classifier, others} = Enum.split_with(cases, &(&1.kind == :classifier))
    ids = MapSet.new(classifier, & &1.id)

    edges =
      Enum.map(near_duplicates(classifier, opts), fn {a, b, _} -> {a, b} end) ++
        shared_edges(classifier, &get_in(&1.provenance, ["template_id"])) ++
        shared_edges(classifier, & &1.group) ++
        for(
          c <- classifier,
          seed = c.provenance["derived_from"],
          MapSet.member?(ids, seed),
          do: {c.id, seed}
        )

    parent = Enum.reduce(edges, Map.new(ids, &{&1, &1}), fn {a, b}, p -> union(p, a, b) end)

    components =
      Enum.group_by(classifier, fn c -> find(parent, c.id) end)
      |> Map.new(fn {root, members} -> {root, component_name(members)} end)

    regrouped = Enum.map(classifier, &%{&1 | group: Map.fetch!(components, find(parent, &1.id))})
    regrouped ++ others
  end

  defp shared_edges(cases, key_fun) do
    cases
    |> Enum.group_by(key_fun, & &1.id)
    |> Enum.flat_map(fn
      {nil, _} -> []
      {_key, [first | rest]} -> Enum.map(rest, &{first, &1})
    end)
  end

  defp component_name(members) do
    declared = for c <- members, c.group && c.group != c.id, do: c.group

    case declared do
      [] -> members |> Enum.map(& &1.id) |> Enum.min()
      names -> Enum.min(names)
    end
  end

  defp find(parent, x) do
    case Map.fetch!(parent, x) do
      ^x -> x
      p -> find(parent, p)
    end
  end

  defp union(parent, a, b) do
    {ra, rb} = {find(parent, a), find(parent, b)}
    if ra == rb, do: parent, else: Map.put(parent, max(ra, rb), min(ra, rb))
  end

  # ── splits ────────────────────────────────────────────────────────────────

  @doc """
  Gives every classifier case its group's split (see the moduledoc).

  Options: `:seed` (default `"nous-guard-v1"`), `:fractions` (keyword of
  `tune`/`holdout`/`test` shares summing to 1, default `0.4/0.3/0.3`).

  Returns `{:error, {:split_conflict, group}}` when a group's members
  declare different splits.
  """
  @spec assign_splits([Case.t()], keyword()) ::
          {:ok, [Case.t()]} | {:error, {:split_conflict, String.t()} | {:invalid_option, atom()}}
  def assign_splits(cases, opts \\ []) do
    seed = Keyword.get(opts, :seed, @default_split_seed)

    with {:ok, cuts} <- split_cuts(Keyword.get(opts, :fractions, @default_fractions)),
         {:ok, by_group} <- group_splits(cases, seed, cuts) do
      {:ok,
       Enum.map(cases, fn
         %Case{kind: :classifier} = c -> %{c | split: Map.fetch!(by_group, c.group)}
         c -> c
       end)}
    end
  end

  @doc """
  The split `group` hashes to under `seed` and the given fractions (see
  `assign_splits/2`).
  """
  @spec hashed_split(String.t(), String.t(), keyword()) :: Case.split()
  def hashed_split(group, seed \\ @default_split_seed, fractions \\ @default_fractions) do
    {:ok, cuts} = split_cuts(fractions)
    bucket_split(group, seed, cuts)
  end

  defp group_splits(cases, seed, cuts) do
    cases
    |> Enum.filter(&(&1.kind == :classifier))
    |> Enum.group_by(& &1.group)
    |> Enum.reduce_while({:ok, %{}}, fn {group, members}, {:ok, acc} ->
      case members |> Enum.map(& &1.split) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
        [] -> {:cont, {:ok, Map.put(acc, group, bucket_split(group, seed, cuts))}}
        [split] -> {:cont, {:ok, Map.put(acc, group, split)}}
        _ -> {:halt, {:error, {:split_conflict, group}}}
      end
    end)
  end

  defp split_cuts(fractions) when is_list(fractions) do
    shares = Enum.map([:tune, :holdout, :test], &Keyword.get(fractions, &1, 0))

    if Enum.all?(shares, &(is_number(&1) and &1 >= 0)) and abs(Enum.sum(shares) - 1) < 1.0e-9 do
      [t, h, _] = shares
      {:ok, {t, t + h}}
    else
      {:error, {:invalid_option, :fractions}}
    end
  end

  defp split_cuts(_), do: {:error, {:invalid_option, :fractions}}

  defp bucket_split(group, seed, {tune_cut, holdout_cut}) do
    <<n::unsigned-64, _::binary>> = :crypto.hash(:sha256, seed <> ":" <> group)
    u = n / 18_446_744_073_709_551_616

    cond do
      u < tune_cut -> :tune
      u < holdout_cut -> :holdout
      true -> :test
    end
  end

  @doc "The split name as written in files."
  @spec split_name(Case.split()) :: String.t()
  def split_name(split), do: Map.fetch!(@split_names, split)

  # ── licences ──────────────────────────────────────────────────────────────

  @doc "The licence policy for an SPDX id: `:in_repo`, `:terms` or `:denied`."
  @spec licence_status(String.t()) :: :in_repo | :terms | :denied
  def licence_status(spdx) when spdx in @in_repo, do: :in_repo
  def licence_status(spdx) when spdx in @terms, do: :terms
  def licence_status(_spdx), do: :denied

  @doc "The licences allowed in the repository."
  @spec in_repo_licences() :: [String.t()]
  def in_repo_licences, do: @in_repo

  @doc """
  Cases whose `provenance.license` the policy does not allow, as
  `[{id, license}]`. `:in_repo` allows only in-repo licences; `:fetch` also
  allows `:terms` licences (whose acceptance the caller records).
  """
  @spec licence_violations([Case.t()], :in_repo | :fetch) :: [{String.t(), String.t()}]
  def licence_violations(cases, policy) when policy in [:in_repo, :fetch] do
    allowed = if policy == :in_repo, do: [:in_repo], else: [:in_repo, :terms]

    for c <- cases,
        license = c.provenance["license"],
        licence_status(license) not in allowed,
        do: {c.id, license}
  end

  # ── PII lint ──────────────────────────────────────────────────────────────

  # A function, not a module attribute: on OTP 28 a compiled regex holds a
  # reference, and Elixir 1.18 cannot inject a list of them into a function.
  defp pii_patterns do
    [
      email: ~r/[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/,
      phone: ~r/(?<![\w.])(?:\+\d{1,3}[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}(?![\w])/,
      card: ~r/(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/,
      iban: ~r/\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/,
      secret:
        ~r/\bsk-[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/
    ]
  end

  @doc """
  PII findings `%{id, kind, value}` over every string in each case's input
  (see the moduledoc for what a case may carry).
  """
  @spec pii_lint([Case.t()]) :: [%{id: String.t(), kind: atom(), value: String.t()}]
  def pii_lint(cases) do
    for c <- cases,
        text <- strings(c.input),
        {kind, regex} <- pii_patterns(),
        [value | _] <- Regex.scan(regex, text),
        valid_hit?(kind, value),
        not allowed?(c, kind, value),
        do: %{id: c.id, kind: kind, value: value}
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(%{} = map), do: Enum.flat_map(map, fn {k, v} -> strings(k) ++ strings(v) end)
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(_), do: []

  defp valid_hit?(:card, value), do: value |> digits() |> luhn?()
  defp valid_hit?(:iban, value), do: iban?(value)
  defp valid_hit?(_kind, _value), do: true

  defp allowed?(%Case{tags: tags}, kind, value) do
    "synthetic_pii" in tags and
      case kind do
        :email -> reserved_email?(value)
        :phone -> value |> digits() |> String.slice(-7, 7) |> String.starts_with?("55501")
        _ -> true
      end
  end

  defp reserved_email?(value) do
    [_, domain] = String.split(value, "@", parts: 2)
    domain = String.downcase(domain)

    domain in @reserved_domains or
      Enum.any?(@reserved_domains, &String.ends_with?(domain, "." <> &1)) or
      Enum.any?(@reserved_tlds, &String.ends_with?(domain, &1))
  end

  defp digits(value), do: String.replace(value, ~r/\D/, "")

  defp luhn?(digits) when byte_size(digits) in 13..19 do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {d, i}, sum ->
      n = String.to_integer(d)
      n = if rem(i, 2) == 1, do: n * 2, else: n
      sum + if(n > 9, do: n - 9, else: n)
    end)
    |> rem(10) == 0
  end

  defp luhn?(_digits), do: false

  defp iban?(value) do
    {head, tail} = String.split_at(value, 4)

    (tail <> head)
    |> String.graphemes()
    |> Enum.map_join(fn
      <<c>> when c in ?A..?Z -> Integer.to_string(c - ?A + 10)
      d -> d
    end)
    |> String.to_integer()
    |> rem(97) == 1
  end

  # ── hashing ───────────────────────────────────────────────────────────────

  @doc """
  The canonical JSONL form of `cases`: records sorted by id, each
  `Nous.Eval.CanonicalJSON` encoded (keys sorted), LF-terminated. Built-in
  files are written in this form, so their bytes hash as `sha256/1` says.
  """
  @spec canonical_jsonl([Case.t()]) :: String.t()
  def canonical_jsonl(cases) do
    cases
    |> Enum.sort_by(& &1.id)
    |> Enum.map_join(fn c -> CanonicalJSON.encode(Case.to_map(c)) <> "\n" end)
  end

  @doc "`\"sha256:<hex>\"` of `canonical_jsonl(cases)`."
  @spec sha256([Case.t()]) :: String.t()
  def sha256(cases), do: CanonicalJSON.digest(canonical_jsonl(cases))
end
