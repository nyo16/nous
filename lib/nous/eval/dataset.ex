defmodule Nous.Eval.Dataset do
  @moduledoc """
  A validated, content-hashed list of `Nous.Eval.Case`s.

  Build one from Elixir with `new/2`, or load YAML/JSONL files with `load/2`.
  Both go through the same validation, so a dataset that loads is one the
  runner can execute.

  ## Elixir

      Nous.Eval.Dataset.new([
        %{id: "refund-1", input: "Refund order 42", tags: ["refund"],
          scorers: [{MyApp.Eval.RefundIssued, required: true}]},
        [id: "greet-1", input: "Hi!"]
      ])

  Cases are `%Nous.Eval.Case{}` structs, maps or keyword lists with atom
  keys. A scorer is a module, `{module, opts}` (opts may carry `:required`,
  `:weight` and `:skippable`) or a `Nous.Eval.Scorer.Spec`.

  ## Files (schema `nous.case/1`)

  YAML holds one document with a schema marker and the case list:

  ```yaml
  schema: nous.case/1
  name: refunds            # optional; defaults to the file name
  cases:
    - id: refund-1
      input: Refund order 42
      expected: {tool: refund_order}
      tags: [refund]
      scorers:
        - no_tool_errors
        - scorer: contains
          values: [refund issued]
          required: false
    - id: refund-2
      input:
        - {role: system, content: You are terse.}
        - {role: user, content: Refund order 43}
      group: refund-2      # paraphrases share a group, and so a split
      split: test
  ```

  JSONL holds one case object per line, with the same keys; a line may carry
  `"schema": "nous.case/1"`. Blank lines are skipped and errors name the line.

  Case keys: `id` (required, non-empty string), `input` (required: a string
  or a list of `{role, content}` messages, roles `system`, `user`,
  `assistant`), `expected` (object), `scorers`, `threshold` (number in
  0..1), `tags` (strings), `split` (`train`, `val`, `test`), `group`
  (string), `metadata` (object). A scorer entry is a scorer name or an object
  whose `scorer` key names it and whose other keys are its options, resolved
  with `Nous.Eval.Scorer.resolve/2`.

  Loading is strict and fails closed: an unknown key, a duplicate id, a
  non-string object key, an unknown role, split or scorer, or an unknown
  scorer option is an `{:error, message}`. Nothing in a file becomes an atom.

  ## Splits

  A case without a `split` gets one from its `group` (default: its id):
  `sha256("nous.split/1:" <> group)` picks a uniform bucket, cut by the split
  ratios (default `train: 0.6, val: 0.2, test: 0.2`, option
  `:split_ratios`). The assignment depends only on the group, so adding or
  removing cases never moves the others, and paraphrases sharing a group
  never straddle splits. When one case of a group declares a split, the
  group's other cases follow it; two different declared splits in one group
  are an error.

  ## Content hash

  `:hash` is `Nous.Eval.CanonicalJSON.hash/1` of the cases sorted by id (with
  their assigned splits). It ignores key order, file format, case order, the
  dataset name and the source path: the same cases in YAML and JSONL hash the
  same. Run records store it to tell which data a run saw.
  """

  alias Nous.Eval.{CanonicalJSON, Case, Fingerprint}
  alias Nous.Eval.Scorer
  alias Nous.Eval.Scorer.Spec
  alias Nous.Message

  @schema "nous.case/1"

  @type t :: %__MODULE__{
          name: String.t() | nil,
          cases: [Case.t()],
          hash: String.t(),
          source: Path.t() | nil
        }

  @enforce_keys [:hash]
  defstruct name: nil, cases: [], hash: nil, source: nil

  @case_fields [:id, :input, :expected, :scorers, :threshold, :tags, :split, :group, :metadata]

  # File keys are matched against literal strings; the atom is only ever one
  # of the struct's own fields.
  @file_keys Map.new(@case_fields, &{Atom.to_string(&1), &1})

  @roles %{"system" => :system, "user" => :user, "assistant" => :assistant}

  @split_order ["train", "val", "test"]
  @default_ratios %{"train" => 0.6, "val" => 0.2, "test" => 0.2}
  @ratio_keys %{train: "train", val: "val", test: "test"}

  @doc "The schema id of the case format (`\"nous.case/1\"`)."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Builds a dataset from Elixir cases.

  `cases` is a list of `%Nous.Eval.Case{}`, maps or keyword lists with atom
  keys.

  ## Options

    * `:name` - the dataset name
    * `:split_ratios` - keyword or map with `:train`, `:val`, `:test` ratios
      (missing keys are 0; they must sum to 1)
  """
  @spec new([Case.t() | map() | keyword()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(cases, opts \\ [])

  def new(cases, opts) when is_list(cases) and is_list(opts) do
    with {:ok, ratios} <- split_ratios(opts),
         {:ok, parsed} <- parse_all(Enum.with_index(cases, 1), &parse_elixir/1) do
      build(parsed, ratios, opts[:name], nil)
    end
  end

  def new(other, _opts), do: {:error, "a dataset is a list of cases, got #{inspect(other)}"}

  @doc """
  Loads a dataset file: `.yaml`/`.yml` or `.jsonl`.

  Takes the options of `new/2`. `:name` defaults to the YAML `name` key,
  then to the file name without extension.
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(path, opts \\ []) when is_binary(path) and is_list(opts) do
    loader =
      case path |> Path.extname() |> String.downcase() do
        ext when ext in [".yaml", ".yml"] -> &load_yaml/2
        ".jsonl" -> &load_jsonl/2
        ext -> {:error, "#{path}: unsupported dataset file type #{inspect(ext)}"}
      end

    with loader when is_function(loader) <- loader,
         {:ok, ratios} <- split_ratios(opts),
         {:ok, cases, file_name} <- loader.(path, Path.basename(path, Path.extname(path))) do
      build(cases, ratios, opts[:name] || file_name, path)
    end
  end

  @doc """
  Keeps the cases matching every given criterion and recomputes the hash.

  ## Options

    * `:splits` - split names; a case must be in one of them
    * `:tags` - tag strings; a case must carry at least one of them

  Raises `ArgumentError` for an unknown split or a non-string tag.
  """
  @spec filter(t(), keyword()) :: t()
  def filter(%__MODULE__{} = dataset, opts) when is_list(opts) do
    splits = opts |> Keyword.get(:splits) |> check_filter_values(:splits, Case.splits())
    tags = opts |> Keyword.get(:tags) |> check_filter_values(:tags, nil)

    cases =
      Enum.filter(dataset.cases, fn c ->
        (splits == nil or c.split in splits) and (tags == nil or Enum.any?(c.tags, &(&1 in tags)))
      end)

    %{dataset | cases: cases, hash: content_hash(cases)}
  end

  defp check_filter_values(nil, _key, _allowed), do: nil

  defp check_filter_values(values, key, allowed) when is_list(values) do
    Enum.each(values, fn value ->
      cond do
        not is_binary(value) ->
          raise ArgumentError, "filter #{key}: values are strings, got #{inspect(value)}"

        allowed != nil and value not in allowed ->
          raise ArgumentError, "filter #{key}: unknown split #{inspect(value)}"

        true ->
          :ok
      end
    end)

    values
  end

  defp check_filter_values(other, key, _allowed) do
    raise ArgumentError, "filter #{key}: expected a list, got #{inspect(other)}"
  end

  @doc false
  # Normalizes Elixir scorer declarations (task `scorers/0`, case `:scorers`)
  # into specs. Also used by `Nous.Eval.Task`.
  @spec scorer_specs(term()) :: {:ok, [Spec.t()]} | {:error, String.t()}
  def scorer_specs(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn decl, {:ok, acc} ->
      case scorer_spec(decl) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  def scorer_specs(other), do: {:error, "scorers must be a list, got #{inspect(other)}"}

  defp scorer_spec(%Spec{module: module} = spec) do
    with :ok <- check_scorer_module(module),
         :ok <- check_opts(module, spec.opts),
         :ok <- check_composition(module, Map.take(spec, [:required, :weight, :skippable])) do
      {:ok, spec}
    end
  end

  defp scorer_spec({module, opts}) when is_atom(module) and is_list(opts) do
    with :ok <- check_scorer_module(module),
         :ok <- check_opts(module, opts) do
      {composition, scorer_opts} = Keyword.split(opts, [:required, :weight, :skippable])

      with :ok <- check_composition(module, composition) do
        {:ok, struct!(Spec, [module: module, opts: scorer_opts] ++ composition)}
      end
    end
  end

  defp scorer_spec(module) when is_atom(module) and module not in [nil, true, false],
    do: scorer_spec({module, []})

  defp scorer_spec(other) do
    {:error,
     "a scorer is a module, {module, opts} or %Nous.Eval.Scorer.Spec{}, got #{inspect(other)}"}
  end

  defp check_scorer_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :score, 2) do
      :ok
    else
      {:error, "#{inspect(module)} is not a Nous.Eval.Scorer (needs init/1 and score/2)"}
    end
  end

  defp check_scorer_module(other), do: {:error, "scorer module expected, got #{inspect(other)}"}

  defp check_opts(module, opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, "scorer #{inspect(module)}: options must be a keyword list"}
  end

  defp check_composition(module, composition) do
    Enum.reduce_while(composition, :ok, fn
      {key, value}, :ok when key in [:required, :skippable] and is_boolean(value) ->
        {:cont, :ok}

      {:weight, value}, :ok when is_number(value) and value >= 0 ->
        {:cont, :ok}

      {key, value}, :ok ->
        {:halt, {:error, "scorer #{inspect(module)}: invalid #{key} #{inspect(value)}"}}
    end)
  end

  # -- Elixir cases ------------------------------------------------------------

  defp parse_elixir({%Case{} = c, index}), do: validate_case(c, case_label(index, c.id))

  defp parse_elixir({fields, index}) when is_list(fields) or is_map(fields) do
    label = case_label(index, nil)

    cond do
      is_list(fields) and not Keyword.keyword?(fields) ->
        {:error, "#{label}: a case is a %Case{}, a map or a keyword list"}

      Enum.any?(fields, fn {key, _} -> not is_atom(key) end) ->
        {:error, "#{label}: Elixir case keys must be atoms"}

      true ->
        map = Map.new(fields)
        label = case_label(index, map[:id])

        case Enum.reject(Map.keys(map), &(&1 in @case_fields)) do
          [] -> validate_case(struct(Case, Map.put_new(map, :input, nil)), label)
          [key | _] -> {:error, "#{label}: unknown key #{inspect(key)}"}
        end
    end
  end

  defp parse_elixir({other, index}) do
    {:error,
     "#{case_label(index, nil)}: a case is a %Case{}, a map or a keyword list, got " <>
       inspect(other)}
  end

  defp validate_case(%Case{} = c, label) do
    with :ok <- check_id(c.id),
         {:ok, input} <- elixir_input(c.input),
         {:ok, scorers} <- scorer_specs(c.scorers),
         {:ok, fields} <- common_fields(c) do
      {:ok, struct!(c, [input: input, scorers: scorers] ++ fields)}
    end
    |> label_error(label)
  end

  defp elixir_input(text) when is_binary(text), do: {:ok, text}

  defp elixir_input([_ | _] = messages) do
    if Enum.all?(messages, &match?(%Message{}, &1)),
      do: {:ok, messages},
      else: {:error, "input messages must be %Nous.Message{} structs"}
  end

  defp elixir_input(other),
    do: {:error, "input must be a string or a non-empty message list, got #{inspect(other)}"}

  # -- Files -------------------------------------------------------------------

  defp load_yaml(path, file_name) do
    with {:ok, content} <- read_file(path) do
      case YamlElixir.read_from_string(content) do
        {:ok, %{} = doc} -> parse_yaml_doc(doc, path, file_name)
        {:ok, _} -> {:error, "#{path}: expected a mapping with \"schema\" and \"cases\""}
        {:error, %{message: message}} -> {:error, "#{path}: invalid YAML: #{message}"}
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "#{path}: cannot read: #{:file.format_error(reason)}"}
    end
  end

  defp parse_yaml_doc(doc, path, file_name) do
    with :ok <- check_known_keys(doc, ["schema", "name", "cases"]),
         :ok <- check_schema(Map.fetch(doc, "schema"), :required),
         {:ok, name} <- yaml_name(Map.get(doc, "name"), file_name),
         {:ok, cases} <- yaml_cases(Map.get(doc, "cases")),
         {:ok, parsed} <- parse_all(Enum.with_index(cases, 1), &parse_file_case/1) do
      {:ok, parsed, name}
    end
    |> prefix_error(path)
  end

  defp yaml_name(nil, file_name), do: {:ok, file_name}
  defp yaml_name(name, _file_name) when is_binary(name) and name != "", do: {:ok, name}
  defp yaml_name(other, _), do: {:error, "name must be a non-empty string, got #{inspect(other)}"}

  defp yaml_cases(cases) when is_list(cases), do: {:ok, cases}
  defp yaml_cases(nil), do: {:error, "missing \"cases\" list"}
  defp yaml_cases(other), do: {:error, "\"cases\" must be a list, got #{inspect(other)}"}

  defp load_jsonl(path, file_name) do
    with {:ok, content} <- read_file(path),
         {:ok, cases} <-
           content
           |> String.split("\n")
           |> Enum.with_index(1)
           |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
           |> parse_all(&parse_jsonl_line/1)
           |> prefix_error(path) do
      {:ok, cases, file_name}
    end
  end

  defp parse_jsonl_line({line, number}) do
    with {:ok, decoded} <- decode_json_line(line),
         {:ok, fields} <- take_line_schema(decoded),
         {:ok, c} <- parse_file_case({fields, :line}) do
      {:ok, c}
    end
    |> label_error("line #{number}")
  end

  defp decode_json_line(line) do
    case JSON.decode(line) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, "expected a JSON object, got #{inspect(other)}"}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  defp take_line_schema(fields) do
    {schema, rest} = Map.pop(fields, "schema")

    with :ok <- check_schema(if(schema, do: {:ok, schema}, else: :error), :optional) do
      {:ok, rest}
    end
  end

  defp check_schema({:ok, @schema}, _), do: :ok
  defp check_schema(:error, :optional), do: :ok

  defp check_schema(:error, :required),
    do: {:error, "missing schema marker \"schema: #{@schema}\""}

  defp check_schema({:ok, other}, _),
    do: {:error, "unsupported schema #{inspect(other)} (expected #{inspect(@schema)})"}

  defp parse_file_case({fields, index}) when is_map(fields) do
    label = if index == :line, do: nil, else: case_label(index, file_id(fields))

    with :ok <- check_string_keys(fields, "case"),
         :ok <- check_known_keys(fields, Map.keys(@file_keys)),
         :ok <- check_id(Map.get(fields, "id")),
         {:ok, input} <- file_input(Map.get(fields, "input")),
         {:ok, scorers} <- file_scorers(Map.get(fields, "scorers", [])),
         c = struct!(Case, id: fields["id"], input: input, scorers: scorers),
         {:ok, common} <- common_fields(file_common(c, fields)) do
      {:ok, struct!(c, common)}
    end
    |> label_error(label || "case #{inspect(file_id(fields))}")
  end

  defp parse_file_case({other, index}) do
    {:error, "#{case_label(index, nil)}: a case must be a mapping, got #{inspect(other)}"}
  end

  defp file_id(fields), do: if(is_binary(fields["id"]), do: fields["id"])

  # Carries the remaining file fields onto the struct for `common_fields/1`,
  # whose checks are shared with Elixir cases; `expected`/`metadata` first get
  # the deep string-key check only files need.
  defp file_common(c, fields) do
    %{
      c
      | expected: Map.get(fields, "expected", %{}),
        metadata: Map.get(fields, "metadata", %{}),
        threshold: Map.get(fields, "threshold"),
        tags: Map.get(fields, "tags", []),
        split: Map.get(fields, "split"),
        group: Map.get(fields, "group")
    }
  end

  defp file_input(text) when is_binary(text), do: {:ok, text}

  defp file_input([_ | _] = messages) do
    messages
    |> Enum.with_index(1)
    |> parse_all(&file_message/1)
    |> label_error("input")
  end

  defp file_input(other),
    do: {:error, "input must be a string or a non-empty message list, got #{inspect(other)}"}

  defp file_message({%{} = message, index}) do
    with :ok <- check_string_keys(message, "message"),
         :ok <- check_known_keys(message, ["role", "content"]),
         {:ok, role} <- message_role(Map.get(message, "role")),
         {:ok, content} <- message_content(Map.get(message, "content")) do
      {:ok, build_message(role, content)}
    end
    |> label_error("message #{index}")
  end

  defp file_message({other, index}),
    do: {:error, "message #{index}: expected a {role, content} mapping, got #{inspect(other)}"}

  defp message_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "role must be one of system, user, assistant, got #{inspect(role)}"}
    end
  end

  defp message_content(content) when is_binary(content), do: {:ok, content}
  defp message_content(other), do: {:error, "content must be a string, got #{inspect(other)}"}

  defp build_message(:system, content), do: Message.system(content)
  defp build_message(:user, content), do: Message.user(content)
  defp build_message(:assistant, content), do: Message.assistant(content)

  defp file_scorers(list) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> parse_all(&file_scorer/1)
    |> label_error("scorers")
  end

  defp file_scorers(other), do: {:error, "scorers must be a list, got #{inspect(other)}"}

  defp file_scorer({name, _index}) when is_binary(name), do: Scorer.resolve(name, %{})

  defp file_scorer({%{"scorer" => name} = entry, _index}) when is_binary(name) do
    Scorer.resolve(name, Map.delete(entry, "scorer"))
  end

  defp file_scorer({other, index}) do
    {:error,
     "scorer #{index}: expected a scorer name or a mapping with a \"scorer\" key, got " <>
       inspect(other)}
  end

  # -- Shared case checks ------------------------------------------------------

  defp check_id(id) when is_binary(id) and id != "", do: :ok
  defp check_id(id), do: {:error, "id must be a non-empty string, got #{inspect(id)}"}

  defp common_fields(%Case{} = c) do
    with {:ok, expected} <- map_field(c.expected, "expected"),
         {:ok, metadata} <- map_field(c.metadata, "metadata"),
         {:ok, threshold} <- threshold(c.threshold),
         {:ok, tags} <- tags(c.tags),
         {:ok, split} <- split(c.split),
         {:ok, group} <- group(c.group, c.id) do
      {:ok,
       [
         expected: expected,
         metadata: metadata,
         threshold: threshold,
         tags: tags,
         split: split,
         group: group
       ]}
    end
  end

  defp map_field(nil, _name), do: {:ok, %{}}
  defp map_field(%{} = map, _name) when not is_struct(map), do: {:ok, map}
  defp map_field(other, name), do: {:error, "#{name} must be a map, got #{inspect(other)}"}

  defp threshold(nil), do: {:ok, nil}
  defp threshold(t) when is_number(t) and t >= 0 and t <= 1, do: {:ok, t / 1}
  defp threshold(t), do: {:error, "threshold must be a number in 0..1, got #{inspect(t)}"}

  defp tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1),
      do: {:ok, Enum.uniq(tags)},
      else: {:error, "tags must be strings, got #{inspect(tags)}"}
  end

  defp tags(other), do: {:error, "tags must be a list of strings, got #{inspect(other)}"}

  defp split(nil), do: {:ok, nil}

  defp split(split) do
    if split in Case.splits(),
      do: {:ok, split},
      else:
        {:error, "split must be one of #{Enum.join(Case.splits(), ", ")}, got #{inspect(split)}"}
  end

  defp group(nil, id), do: {:ok, id}
  defp group(group, _id) when is_binary(group) and group != "", do: {:ok, group}
  defp group(other, _id), do: {:error, "group must be a non-empty string, got #{inspect(other)}"}

  defp check_known_keys(map, allowed) do
    case Enum.reject(Map.keys(map), &(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, "unknown key #{unknown |> Enum.sort() |> hd() |> inspect()}"}
    end
  end

  # Files must give string keys at every depth: YAML can produce integer or
  # boolean keys, which would not survive a JSON round trip of the run record.
  defp check_string_keys(term, where) do
    if string_keys?(term),
      do: :ok,
      else: {:error, "#{where}: object keys must be strings"}
  end

  defp string_keys?(%{} = map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and string_keys?(value) end)

  defp string_keys?(list) when is_list(list), do: Enum.all?(list, &string_keys?/1)
  defp string_keys?(_), do: true

  # -- Building ----------------------------------------------------------------

  defp build(cases, ratios, name, source) do
    with :ok <- check_unique_ids(cases),
         {:ok, cases} <- assign_splits(cases, ratios) do
      {:ok, %__MODULE__{name: name, cases: cases, hash: content_hash(cases), source: source}}
    end
    |> prefix_error(source)
  end

  defp check_unique_ids(cases) do
    cases
    |> Enum.frequencies_by(& &1.id)
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> case do
      [] -> :ok
      ids -> {:error, "duplicate case ids: #{Enum.map_join(ids, ", ", &inspect/1)}"}
    end
  end

  defp assign_splits(cases, ratios) do
    declared =
      cases
      |> Enum.filter(& &1.split)
      |> Enum.group_by(& &1.group, & &1.split)
      |> Enum.map(fn {group, splits} -> {group, Enum.uniq(splits)} end)

    case Enum.find(declared, fn {_group, splits} -> length(splits) > 1 end) do
      {group, splits} ->
        {:error,
         "group #{inspect(group)} declares different splits: #{Enum.join(Enum.sort(splits), ", ")}"}

      nil ->
        by_group = Map.new(declared, fn {group, [split]} -> {group, split} end)

        {:ok,
         Enum.map(cases, fn c ->
           %{c | split: c.split || Map.get(by_group, c.group) || bucket(c.group, ratios)}
         end)}
    end
  end

  defp bucket(group, ratios) do
    <<n::unsigned-64, _::binary>> = :crypto.hash(:sha256, "nous.split/1:" <> group)
    u = n / 18_446_744_073_709_551_616

    {_cum, split} =
      Enum.reduce_while(@split_order, {0.0, nil}, fn split, {cum, _} ->
        cum = cum + Map.fetch!(ratios, split)
        if u < cum, do: {:halt, {cum, split}}, else: {:cont, {cum, split}}
      end)

    # Float rounding can leave u above the last cumulative sum; the last split
    # with a non-zero ratio takes it.
    if Map.fetch!(ratios, split) > 0,
      do: split,
      else: Enum.find(Enum.reverse(@split_order), &(Map.fetch!(ratios, &1) > 0))
  end

  defp split_ratios(opts) do
    case Keyword.fetch(opts, :split_ratios) do
      :error ->
        {:ok, @default_ratios}

      {:ok, ratios} when is_list(ratios) or is_map(ratios) ->
        parse_ratios(ratios)

      {:ok, other} ->
        {:error, "split_ratios must be a keyword list or map, got #{inspect(other)}"}
    end
  end

  defp parse_ratios(ratios) do
    parsed =
      Enum.reduce_while(ratios, {:ok, %{"train" => 0, "val" => 0, "test" => 0}}, fn
        {key, value}, {:ok, acc} when is_number(value) and value >= 0 ->
          case Map.fetch(@ratio_keys, key) do
            {:ok, split} -> {:cont, {:ok, Map.put(acc, split, value)}}
            :error -> {:halt, {:error, "split_ratios: unknown split #{inspect(key)}"}}
          end

        entry, _acc ->
          {:halt, {:error, "split_ratios: invalid entry #{inspect(entry)}"}}
      end)

    with {:ok, map} <- parsed do
      if abs(Enum.sum(Map.values(map)) - 1.0) < 1.0e-9,
        do: {:ok, map},
        else: {:error, "split_ratios must sum to 1, got #{inspect(ratios)}"}
    end
  end

  defp content_hash(cases) do
    CanonicalJSON.hash(%{
      "schema" => @schema,
      "cases" => cases |> Enum.sort_by(& &1.id) |> Enum.map(&canonical_case/1)
    })
  end

  defp canonical_case(%Case{} = c) do
    %{
      "id" => c.id,
      "input" => canonical_input(c.input),
      "expected" => Fingerprint.term(c.expected, "case #{inspect(c.id)} expected"),
      "scorers" => Enum.map(c.scorers, &canonical_spec(&1, c.id)),
      "threshold" => c.threshold,
      "tags" => Enum.sort(c.tags),
      "split" => c.split,
      "group" => c.group,
      "metadata" => Fingerprint.term(c.metadata, "case #{inspect(c.id)} metadata")
    }
  end

  defp canonical_input(text) when is_binary(text), do: text

  defp canonical_input(messages) do
    Enum.map(messages, fn %Message{} = m ->
      %{"role" => Atom.to_string(m.role), "content" => m.content}
      |> put_present("tool_calls", Fingerprint.term(m.tool_calls, "input tool calls"))
      |> put_present("tool_call_id", m.tool_call_id)
      |> put_present("name", m.name)
    end)
  end

  defp put_present(map, _key, value) when value in [nil, []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp canonical_spec(%Spec{} = spec, id) do
    %{
      "scorer" => Atom.to_string(spec.module),
      "opts" => Fingerprint.term(spec.opts, "case #{inspect(id)} scorer #{inspect(spec.module)}"),
      "required" => spec.required,
      "weight" => spec.weight,
      "skippable" => spec.skippable
    }
  end

  # -- Helpers -----------------------------------------------------------------

  defp parse_all(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp case_label(index, nil), do: "case #{index}"
  defp case_label(index, id), do: "case #{index} (#{inspect(id)})"

  defp label_error({:error, message}, label), do: {:error, "#{label}: #{message}"}
  defp label_error(ok, _label), do: ok

  defp prefix_error(result, nil), do: result
  defp prefix_error({:error, message}, path), do: {:error, "#{path}: #{message}"}
  defp prefix_error(ok, _path), do: ok
end
