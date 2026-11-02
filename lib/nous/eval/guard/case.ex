defmodule Nous.Eval.Guard.Case do
  @moduledoc """
  One guard case in the `nous.guard_case/1` schema: a labelled guard input
  for calibration (`kind: "classifier"`) or a decision-table row for a
  deterministic guard (`"permission"`, `"loop_guard"`, `"hook"`).

  ```json
  {"schema": "nous.guard_case/1",
   "id": "deepset-110",
   "kind": "classifier",
   "surface": "user_input",
   "label": "block",
   "split": "holdout",
   "severity": "normal",
   "category": "prompt_injection",
   "tags": ["hard_negative"],
   "group": "jackhhao/dan-template",
   "input": {"text": "Forget everything ..."},
   "expected": {"acceptable": ["escalate", "deny"]},
   "provenance": {"source": "deepset/prompt-injections (test split)",
                  "source_url": "https://huggingface.co/datasets/deepset/prompt-injections",
                  "license": "Apache-2.0", "public": true, "label_source": "upstream"}}
  ```

  ## Keys

    * `schema` - `"nous.guard_case/1"` (required)
    * `id` - non-empty string, unique within a dataset (required)
    * `kind` - `"classifier"` (default), `"permission"`, `"loop_guard"` or
      `"hook"`
    * `surface` - classifier cases: `"user_input"`, `"tool_call"`,
      `"tool_result"` or `"model_output"` (required)
    * `label` - classifier cases: `"block"`, `"allow"` or `null` (an
      unlabelled item, e.g. promoted from online eval and not yet reviewed;
      never calibrated on). The key is required.
    * `split` - classifier cases: `"tune"`, `"holdout"` or `"test"` (required)
    * `severity` - `"normal"` (default) or `"critical"` (zero tolerance in the
      non-regression gate)
    * `category` - free text (the pack question or attack class)
    * `tags` - strings (`"hard_negative"`, `"upstream_train_overlap"`,
      `"synthetic_pii"`, ...)
    * `group` - cluster id for clustered intervals and leakage-free splits;
      defaults to `id`
    * `guard` - deterministic kinds: the name of the guard fixture the caller
      registers (policies and hooks are code, so cases never carry it)
    * `input` - the guard input (required), by surface:
      * `user_input`: `text` (string); optional `attachments`, a list of
        `{"media_type": "text/...", "text": ...}` documents
      * `tool_call`: `tool` (`{name, description?, category?}`),
        `arguments` (object), optional `task`
      * `tool_result`: `tool`, `result` (string or JSON), optional
        `arguments` and `task`
      * `model_output`: `content` (string), optional `tool_calls` (list) and
        `task`

      Without `tool.description` the description comes from the agent under
      test (see `Nous.Eval.Guard.Subject`).
    * `expected` - classifier cases: optional `{"acceptable": [verdicts]}`
      (default: `["escalate", "deny"]` for `block`, `["allow"]` for
      `allow`); deterministic kinds: the expected output (required)
    * `provenance` - required object: `source` and `license` (strings) plus
      the optional `source_url`, `license_url`, `license_note`,
      `attribution`, `source_revision`, `source_split`, `source_row`,
      `public` (boolean), `label_source` (`human`, `upstream`, `generated`,
      `llm_judge`, `promoted_reviewed`), `upstream_label`, `template_id`,
      `derived_from`, `transforms`, `generator`, `redacted`,
      `promoted_from`, `review` (`"pending"` or `"approved"`), `reviewed`
      (`{by, at}`) and `duplicates`

  Loading is strict: an unknown key at any level the schema defines, a wrong
  type or an unknown enum value is an error. Enum values map through literal
  tables; nothing read from a file becomes an atom, and `input`,
  `expected` and `provenance` stay string-keyed.

  ## Certification

  A case whose `provenance.review` is `"pending"` (a generated or promoted
  item no maintainer has approved) is not `certifiable?/1`: calibration
  reports and the non-regression gate leave it out of `test`-split claims.
  """

  alias Nous.Eval.CanonicalJSON

  @schema "nous.guard_case/1"

  @kinds %{
    "classifier" => :classifier,
    "permission" => :permission,
    "loop_guard" => :loop_guard,
    "hook" => :hook
  }
  @surfaces %{
    "user_input" => :user_input,
    "tool_call" => :tool_call,
    "tool_result" => :tool_result,
    "model_output" => :model_output
  }
  @labels %{"block" => :block, "allow" => :allow}
  @splits %{"tune" => :tune, "holdout" => :holdout, "test" => :test}
  @severities %{"normal" => :normal, "critical" => :critical}
  @verdicts %{"allow" => :allow, "escalate" => :escalate, "deny" => :deny}
  @label_sources ~w(human upstream generated llm_judge promoted_reviewed)
  @reviews ~w(pending approved)

  @top_keys ~w(schema id kind surface label split severity category tags group guard input expected provenance)
  @provenance_keys ~w(source source_url license license_url license_note attribution source_revision
                      source_split source_row public label_source upstream_label template_id derived_from
                      transforms generator redacted promoted_from review reviewed duplicates)
  @tool_keys ~w(name description category)
  @input_keys %{
    user_input: {~w(text), ~w(attachments)},
    tool_call: {~w(tool arguments), ~w(task)},
    tool_result: {~w(tool result), ~w(arguments task)},
    model_output: {~w(content), ~w(tool_calls task)}
  }

  @type kind :: :classifier | :permission | :loop_guard | :hook
  @type surface :: :user_input | :tool_call | :tool_result | :model_output
  @type label :: :block | :allow
  @type split :: :tune | :holdout | :test
  @type verdict :: :allow | :escalate | :deny

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          surface: surface() | nil,
          label: label() | nil,
          split: split() | nil,
          severity: :normal | :critical,
          category: String.t() | nil,
          tags: [String.t()],
          group: String.t(),
          guard: String.t() | nil,
          input: map(),
          expected: map() | nil,
          provenance: map()
        }

  @enforce_keys [:id, :kind, :input, :provenance]
  defstruct [
    :id,
    :surface,
    :label,
    :split,
    :category,
    :guard,
    :group,
    :expected,
    kind: :classifier,
    severity: :normal,
    tags: [],
    input: %{},
    provenance: %{}
  ]

  @doc "The schema id (`\"nous.guard_case/1\"`)."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The surfaces a classifier case may name."
  @spec surfaces() :: [surface()]
  def surfaces, do: [:user_input, :tool_call, :tool_result, :model_output]

  @doc """
  Builds a case from its decoded JSON form (string keys).

  Returns `{:error, message}` naming the case and the offending key.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{} = map) do
    id = Map.get(map, "id")

    with :ok <- check_schema(map),
         :ok <- check_keys(map, @top_keys, "case"),
         {:ok, id} <- non_empty_string(id, "id"),
         {:ok, kind} <- enum(Map.get(map, "kind", "classifier"), @kinds, "kind"),
         {:ok, fields} <- kind_fields(kind, map),
         {:ok, severity} <- enum(Map.get(map, "severity", "normal"), @severities, "severity"),
         {:ok, category} <- optional_string(Map.get(map, "category"), "category"),
         {:ok, tags} <- string_list(Map.get(map, "tags", []), "tags"),
         {:ok, group} <- optional_string(Map.get(map, "group"), "group"),
         {:ok, provenance} <- provenance(Map.get(map, "provenance")) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(fields, %{
           id: id,
           kind: kind,
           severity: severity,
           category: category,
           tags: tags,
           group: group || id,
           provenance: provenance
         })
       )}
    else
      {:error, message} -> {:error, "case #{inspect(id)}: #{message}"}
    end
  end

  def from_map(other), do: {:error, "a guard case is a JSON object, got #{inspect(other)}"}

  @doc """
  The case as JSON-native data (string keys), the inverse of `from_map/1`.
  Optional keys that are unset are left out; `group` is written only when it
  differs from `id`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = c) do
    %{
      "schema" => @schema,
      "id" => c.id,
      "kind" => Atom.to_string(c.kind),
      "input" => c.input,
      "provenance" => c.provenance
    }
    |> put_unless("surface", c.surface && Atom.to_string(c.surface), nil)
    |> put_label(c)
    |> put_unless("split", c.split && Atom.to_string(c.split), nil)
    |> put_unless("severity", Atom.to_string(c.severity), "normal")
    |> put_unless("category", c.category, nil)
    |> put_unless("tags", c.tags, [])
    |> put_unless("group", c.group, c.id)
    |> put_unless("guard", c.guard, nil)
    |> put_unless("expected", c.expected, nil)
  end

  # The key is required for classifier cases, so a null label is written.
  defp put_label(map, %__MODULE__{kind: :classifier, label: label}),
    do: Map.put(map, "label", label && Atom.to_string(label))

  defp put_label(map, %__MODULE__{label: nil}), do: map
  defp put_label(map, %__MODULE__{label: label}), do: Map.put(map, "label", Atom.to_string(label))

  defp put_unless(map, _key, value, value), do: map
  defp put_unless(map, key, value, _default), do: Map.put(map, key, value)

  @doc """
  The verdicts that count as correct for a classifier case: `expected.acceptable`
  when given, else `[:escalate, :deny]` for `block` and `[:allow]` for
  `allow` (`[]` for an unlabelled case).
  """
  @spec acceptable(t()) :: [verdict()]
  def acceptable(%__MODULE__{expected: %{"acceptable" => list}}),
    do: Enum.map(list, &Map.fetch!(@verdicts, &1))

  def acceptable(%__MODULE__{label: :block}), do: [:escalate, :deny]
  def acceptable(%__MODULE__{label: :allow}), do: [:allow]
  def acceptable(%__MODULE__{}), do: []

  @doc """
  Whether the case may back a certification claim: it is labelled and not
  awaiting review (`provenance.review` is not `"pending"`).
  """
  @spec certifiable?(t()) :: boolean()
  def certifiable?(%__MODULE__{label: nil}), do: false
  def certifiable?(%__MODULE__{provenance: %{"review" => "pending"}}), do: false
  def certifiable?(%__MODULE__{}), do: true

  @doc """
  `"sha256:<hex>"` of the canonical input, surface, kind and label: changes
  whenever the case's content changes under a stable id.
  """
  @spec content_sha256(t()) :: String.t()
  def content_sha256(%__MODULE__{} = c) do
    CanonicalJSON.hash(%{
      "kind" => Atom.to_string(c.kind),
      "surface" => c.surface && Atom.to_string(c.surface),
      "label" => c.label && Atom.to_string(c.label),
      "input" => c.input,
      "expected" => c.expected
    })
  end

  # ── validation ────────────────────────────────────────────────────────────

  defp check_schema(%{"schema" => @schema}), do: :ok

  defp check_schema(%{"schema" => other}),
    do: {:error, "schema must be #{inspect(@schema)}, got #{inspect(other)}"}

  defp check_schema(_map), do: {:error, "missing \"schema\": #{inspect(@schema)}"}

  defp check_keys(map, allowed, where) do
    case Enum.reject(Map.keys(map), &(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, "unknown #{where} key(s) #{inspect(Enum.sort(unknown))}"}
    end
  end

  defp kind_fields(:classifier, map) do
    with :ok <- reject_key(map, "guard", "classifier cases name no guard fixture"),
         {:ok, surface} <- required_enum(map, "surface", @surfaces),
         {:ok, label} <- label(map),
         {:ok, split} <- required_enum(map, "split", @splits),
         {:ok, input} <- input(surface, Map.get(map, "input")),
         {:ok, expected} <- classifier_expected(Map.get(map, "expected")) do
      {:ok, %{surface: surface, label: label, split: split, input: input, expected: expected}}
    end
  end

  defp kind_fields(_deterministic, map) do
    with {:ok, guard} <- non_empty_string(Map.get(map, "guard"), "guard"),
         {:ok, label} <- optional_enum(Map.get(map, "label"), @labels, "label"),
         {:ok, split} <- optional_enum(Map.get(map, "split"), @splits, "split"),
         {:ok, input} <- object(Map.get(map, "input"), "input"),
         {:ok, expected} <- object(Map.get(map, "expected"), "expected") do
      {:ok,
       %{surface: nil, guard: guard, label: label, split: split, input: input, expected: expected}}
    end
  end

  defp reject_key(map, key, message),
    do: if(Map.has_key?(map, key), do: {:error, message}, else: :ok)

  defp label(map) do
    case Map.fetch(map, "label") do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> enum(value, @labels, "label")
      :error -> {:error, "missing \"label\" (\"block\", \"allow\" or null)"}
    end
  end

  defp input(surface, %{} = input) do
    {required, optional} = Map.fetch!(@input_keys, surface)

    with :ok <- check_keys(input, required ++ optional, "#{surface} input"),
         :ok <- require_keys(input, required, "#{surface} input") do
      surface_input(surface, input)
    end
  end

  defp input(_surface, other), do: {:error, "input must be an object, got #{inspect(other)}"}

  defp require_keys(map, keys, where) do
    case Enum.reject(keys, &Map.has_key?(map, &1)) do
      [] -> :ok
      missing -> {:error, "#{where} is missing #{inspect(missing)}"}
    end
  end

  defp surface_input(:user_input, input) do
    with {:ok, _} <- string(input["text"], "input.text"),
         :ok <- attachments(Map.get(input, "attachments", [])) do
      {:ok, input}
    end
  end

  defp surface_input(:tool_call, input) do
    with :ok <- tool(input["tool"]),
         {:ok, _} <- object(input["arguments"], "input.arguments"),
         {:ok, _} <- optional_string(input["task"], "input.task") do
      {:ok, input}
    end
  end

  defp surface_input(:tool_result, input) do
    with :ok <- tool(input["tool"]),
         :ok <- json_value(input["result"], "input.result"),
         :ok <- optional_object(input["arguments"], "input.arguments"),
         {:ok, _} <- optional_string(input["task"], "input.task") do
      {:ok, input}
    end
  end

  defp surface_input(:model_output, input) do
    with {:ok, _} <- string(input["content"], "input.content"),
         :ok <- optional_list(input["tool_calls"], "input.tool_calls"),
         {:ok, _} <- optional_string(input["task"], "input.task") do
      {:ok, input}
    end
  end

  defp attachments(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn
      %{"media_type" => "text/" <> _, "text" => text} = a, :ok
      when is_binary(text) and map_size(a) == 2 ->
        {:cont, :ok}

      other, :ok ->
        {:halt,
         {:error,
          "an attachment is {\"media_type\": \"text/...\", \"text\": string}, got #{inspect(other)}"}}
    end)
  end

  defp attachments(other), do: {:error, "input.attachments must be a list, got #{inspect(other)}"}

  defp tool(%{} = tool) do
    with :ok <- check_keys(tool, @tool_keys, "input.tool"),
         {:ok, _} <- non_empty_string(tool["name"], "input.tool.name"),
         {:ok, _} <- optional_string(tool["description"], "input.tool.description"),
         {:ok, _} <- optional_string(tool["category"], "input.tool.category") do
      :ok
    end
  end

  defp tool(other), do: {:error, "input.tool must be an object, got #{inspect(other)}"}

  defp classifier_expected(nil), do: {:ok, nil}

  defp classifier_expected(%{"acceptable" => [_ | _] = list} = expected)
       when map_size(expected) == 1 do
    if Enum.all?(list, &Map.has_key?(@verdicts, &1)),
      do: {:ok, %{"acceptable" => Enum.uniq(list)}},
      else: {:error, "expected.acceptable must list \"allow\", \"escalate\" or \"deny\""}
  end

  defp classifier_expected(other),
    do: {:error, "expected must be {\"acceptable\": [verdict, ...]}, got #{inspect(other)}"}

  defp provenance(%{} = p) do
    with :ok <- check_keys(p, @provenance_keys, "provenance"),
         {:ok, _} <- non_empty_string(p["source"], "provenance.source"),
         {:ok, _} <- non_empty_string(p["license"], "provenance.license"),
         :ok <- optional_strings(p, ~w(source_url license_url license_note attribution
                                      source_revision source_split upstream_label template_id
                                      derived_from)),
         :ok <- optional_boolean(p, ~w(public redacted)),
         :ok <- optional_member(p["label_source"], @label_sources, "provenance.label_source"),
         :ok <- optional_member(p["review"], @reviews, "provenance.review"),
         :ok <- source_row(p["source_row"]),
         :ok <- optional_list(p["transforms"], "provenance.transforms"),
         :ok <- optional_list(p["duplicates"], "provenance.duplicates"),
         :ok <- optional_object(p["generator"], "provenance.generator"),
         :ok <- optional_object(p["promoted_from"], "provenance.promoted_from"),
         :ok <- reviewed(p) do
      {:ok, p}
    end
  end

  defp provenance(nil), do: {:error, "missing \"provenance\""}
  defp provenance(other), do: {:error, "provenance must be an object, got #{inspect(other)}"}

  defp reviewed(%{"review" => "approved"} = p) do
    case p["reviewed"] do
      %{"by" => by, "at" => at} when is_binary(by) and is_binary(at) -> :ok
      _ -> {:error, "provenance.review \"approved\" needs provenance.reviewed {\"by\", \"at\"}"}
    end
  end

  defp reviewed(p), do: optional_object(p["reviewed"], "provenance.reviewed")

  defp source_row(nil), do: :ok
  defp source_row(row) when is_integer(row) and row >= 0, do: :ok
  defp source_row(row) when is_binary(row) and row != "", do: :ok

  defp source_row(other),
    do: {:error, "provenance.source_row must be an index or an id, got #{inspect(other)}"}

  # ── primitives ────────────────────────────────────────────────────────────

  defp required_enum(map, key, table) do
    case Map.fetch(map, key) do
      {:ok, value} -> enum(value, table, key)
      :error -> {:error, "missing #{inspect(key)}"}
    end
  end

  defp optional_enum(nil, _table, _key), do: {:ok, nil}
  defp optional_enum(value, table, key), do: enum(value, table, key)

  defp enum(value, table, key) do
    case Map.fetch(table, value) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "#{key} must be one of #{inspect(table |> Map.keys() |> Enum.sort())}, got #{inspect(value)}"}
    end
  end

  defp optional_member(nil, _allowed, _key), do: :ok

  defp optional_member(value, allowed, key) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}"}
  end

  defp non_empty_string(value, key) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, "#{key} must be a non-empty string"},
      else: {:ok, value}
  end

  defp non_empty_string(nil, key), do: {:error, "missing #{inspect(key)}"}

  defp non_empty_string(other, key),
    do: {:error, "#{key} must be a string, got #{inspect(other)}"}

  defp string(value, _key) when is_binary(value), do: {:ok, value}
  defp string(other, key), do: {:error, "#{key} must be a string, got #{inspect(other)}"}

  defp optional_string(nil, _key), do: {:ok, nil}
  defp optional_string(value, key), do: string(value, key)

  defp optional_strings(map, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case optional_string(map[key], "provenance.#{key}") do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp optional_boolean(map, keys) do
    case Enum.find(keys, &(map[&1] != nil and not is_boolean(map[&1]))) do
      nil -> :ok
      key -> {:error, "provenance.#{key} must be a boolean"}
    end
  end

  defp string_list(list, key) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: {:error, "#{key} must be a list of strings"}
  end

  defp string_list(other, key), do: {:error, "#{key} must be a list, got #{inspect(other)}"}

  defp object(%{} = map, _key), do: {:ok, map}
  defp object(nil, key), do: {:error, "missing #{inspect(key)}"}
  defp object(other, key), do: {:error, "#{key} must be an object, got #{inspect(other)}"}

  defp optional_object(nil, _key), do: :ok
  defp optional_object(%{}, _key), do: :ok

  defp optional_object(other, key),
    do: {:error, "#{key} must be an object, got #{inspect(other)}"}

  defp optional_list(nil, _key), do: :ok
  defp optional_list(list, _key) when is_list(list), do: :ok
  defp optional_list(other, key), do: {:error, "#{key} must be a list, got #{inspect(other)}"}

  defp json_value(nil, key), do: {:error, "missing #{inspect(key)}"}
  defp json_value(_value, _key), do: :ok
end
