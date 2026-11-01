defmodule Nous.Profile do
  @moduledoc """
  A versioned, content-addressed replacement for an agent's prompt text.

  A profile carries **text only**: the agent's instructions, tool
  descriptions and tool parameter descriptions. Tool names, types,
  `required` lists, enums and defaults always come from the live agent, so a
  profile can change what the model reads but never the call contract.

      profile = Nous.Profile.load!("priv/profiles/support_agent.json")
      agent = Nous.new("anthropic:claude-sonnet-4-5", instructions: @base, tools: tools, profile: profile)

      # Per run: another profile, or none (the base text)
      Nous.run(agent, prompt, profile: candidate)
      Nous.run(agent, prompt, profile: nil)

  ## Components

  `components` maps a key to the text that replaces the addressed base:

    * `"instructions"` - the agent's instructions (its `:instructions`, else
      its `:system_prompt`)
    * `"tool:<name>"` - the description of the agent tool named `<name>`
    * `"tool:<name>#<pointer>"` - the `"description"` of the parameter schema
      node at the JSON pointer (RFC 6901 escaping). The pointer walks
      `/properties/<name>`, `/items`, `/additionalProperties` and
      `/anyOf|oneOf|allOf/<index>`; `"tool:<name>#"` is the root object.

  Keys under `skill:`, `guard:`, `router:`, `output:` and `agent:` are
  reserved and rejected. Text built into Nous (plugin, behaviour, skill and
  guard prompts, built-in tools) is not addressable: it changes through a
  reviewed release, not a runtime artifact. Instructions are at most 64 KiB
  and each description at most 8 KiB; text must be non-blank UTF-8 without
  NUL bytes.

  ## Manifest: failing closed on a changed base

  `manifest` holds the hash of each base a component replaces:
  `"instructions"` the hash of the base instruction text, `"tool:<name>"` the
  hash of the tool's whole contract (description and parameters). Applying a
  profile recomputes them from the live agent and fails with `:stale` on any
  difference, so a profile never silently overwrites text a developer has
  since changed. `seal/2` fills the manifest from an agent.

  ## Identity

  `id` is `"sha256:" <> hex` of the canonical JSON (`Nous.Eval.CanonicalJSON`)
  of `%{"schema", "components", "manifest"}`. `name`, `version`, `parent_id`
  and `provenance` are not hashed, so identical text over an identical base
  has one id whoever produced it.

  ## File format

  `encode/1` writes the canonical JSON form, with the tool components nested
  so tool names need no escaping:

      {"components":{"instructions":"...","tools":{"search_orders":{
        "description":"...","params":{"/properties/status":"..."}}}},
       "id":"sha256:...","manifest":{"instructions":"sha256:...",
       "tool:search_orders":"sha256:..."},"name":"support_agent","nous_profile":1}

  `load/1` also reads YAML (`.yaml`/`.yml`) for hand-written profiles, which
  may omit `id` (it is computed) and `manifest` (see `seal/2`). Keys are
  matched against a fixed whitelist; no atom is created from a file.
  """

  import Kernel, except: [apply: 2]

  alias Nous.{Agent, Tool}
  alias Nous.Errors.ProfileError
  alias Nous.Eval.CanonicalJSON
  alias Nous.Profile.Applied

  @schema 1

  @max_instructions_bytes 65_536
  @max_description_bytes 8_192
  @max_note_chars 5_000

  @top_level_fields ~w(nous_profile id name version parent_id components manifest provenance)
  @tool_entry_fields ~w(description params)
  @reserved_prefixes ~w(skill: guard: router: output: agent:)
  @reserved_groups ~w(skill skills guard guards router routers output outputs agent agents)
  @sources ~w(optimizer manual import)

  # What an absent base instruction text hashes as, so a profile may add
  # instructions to an agent that has none.
  @nil_marker "\0nil"

  # JSON-schema keywords a pointer walks, with the atom a hand-written
  # (atom-keyed) schema uses: a fixed table, so no atom comes from input.
  @schema_keys %{
    "properties" => :properties,
    "items" => :items,
    "additionalProperties" => :additionalProperties,
    "anyOf" => :anyOf,
    "oneOf" => :oneOf,
    "allOf" => :allOf
  }

  @enforce_keys [:id, :components, :manifest]
  defstruct [
    :id,
    :name,
    :version,
    :parent_id,
    schema: @schema,
    components: %{},
    manifest: %{},
    provenance: %{}
  ]

  @typedoc """
    * `:id` - `"sha256:<hex>"` content hash (see the moduledoc)
    * `:name` - logical name, `~r/\\A[a-z0-9][a-z0-9_.-]{0,63}\\z/`, or nil
    * `:version` - positive integer a store assigns under `name`, or nil
    * `:parent_id` - id of the profile this one was derived from, or nil
    * `:schema` - serialization schema version (`1`)
    * `:components` - component key => replacement text
    * `:manifest` - `"instructions" | "tool:<name>"` => hash of the base
    * `:provenance` - free-form audit data with string keys (`"source"`,
      `"run_ids"`, `"note"`, ...); not hashed
  """
  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          version: pos_integer() | nil,
          parent_id: String.t() | nil,
          schema: pos_integer(),
          components: %{optional(String.t()) => String.t()},
          manifest: %{optional(String.t()) => String.t()},
          provenance: map()
        }

  # ── serialization ───────────────────────────────────────────────────────────

  @doc """
  Builds a profile from its decoded file form (string keys).

  `id` is computed; a declared `id` must match it. `manifest` may be absent
  (an unsealed profile, see `seal/2`).
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, ProfileError.t()}
  def from_map(%{} = map) do
    with :ok <- check_marker(map),
         :ok <- check_fields(map),
         {:ok, components} <- decode_components(Map.get(map, "components")),
         {:ok, manifest} <- decode_manifest(Map.get(map, "manifest")) do
      profile = %__MODULE__{
        id: Map.get(map, "id"),
        name: Map.get(map, "name"),
        version: Map.get(map, "version"),
        parent_id: Map.get(map, "parent_id"),
        schema: Map.fetch!(map, "nous_profile"),
        components: components,
        manifest: manifest,
        provenance: Map.get(map, "provenance") || %{}
      }

      with :ok <- check_struct(profile), :ok <- check_id(profile) do
        {:ok, %{profile | id: compute_id(profile)}}
      end
    end
  end

  def from_map(_other), do: error(:not_a_profile, nil, "expected a map")

  @doc """
  The file form of `profile`: string keys, tool components nested under
  `"tools"`. `name`, `version`, `parent_id` and `provenance` appear only when
  set.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    %{
      "nous_profile" => profile.schema,
      "id" => profile.id || compute_id(profile),
      "components" => nest_components(profile.components),
      "manifest" => profile.manifest
    }
    |> put_present("name", profile.name)
    |> put_present("version", profile.version)
    |> put_present("parent_id", profile.parent_id)
    |> put_present("provenance", if(profile.provenance == %{}, do: nil, else: profile.provenance))
  end

  @doc "Canonical JSON of `to_map/1`: byte-stable, keys sorted at every level."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = profile), do: profile |> to_map() |> CanonicalJSON.encode()

  @doc """
  Reads a profile file: JSON (`.json`) or YAML (`.yaml`, `.yml`).
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, ProfileError.t()}
  def load(path) do
    with {:ok, text} <- read_file(path),
         {:ok, data} <- decode_file(path, text) do
      from_map(data)
    end
  end

  @doc "As `load/1`, raising `Nous.Errors.ProfileError`."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, profile} -> profile
      {:error, error} -> raise error
    end
  end

  # ── validation and application ─────────────────────────────────────────────

  @doc """
  Checks that `profile` applies to `agent`, without applying it.

  The checks run in order and stop at the first failure: schema, the
  structure (component and manifest keys, text values, `name`, `version`,
  `parent_id`, `provenance`), id, `:dynamic_instructions`, the addressed tools
  (`:unknown_tool`, `:ambiguous_tool`, `:builtin_tool`), the parameter
  pointers (`:unknown_param`), and the manifest (`:missing_manifest`,
  `:stale`). An agent that already has a profile is checked against its
  base text, not the applied text.
  """
  @spec validate(t(), Agent.t()) :: :ok | {:error, ProfileError.t()}
  def validate(%__MODULE__{} = profile, %Agent{} = agent) do
    with {:ok, _agent} <- apply(profile, agent), do: :ok
  end

  def validate(other, %Agent{}), do: not_a_profile(other)

  @doc """
  Returns `agent` running `profile`, or with its base text restored for
  `nil`.

  All or nothing: the patched agent is returned only when every check of
  `validate/2` passes. A profile replaces the base text, never another
  profile's text: applying to an agent that already has one starts from its
  base. Tools whose description is replaced keep the original in
  `:base_description` (what `Nous.Hook.Decision` shows a guard model).
  """
  @spec apply(t() | nil, Agent.t()) :: {:ok, Agent.t()} | {:error, ProfileError.t()}
  def apply(nil, %Agent{} = agent), do: {:ok, base_agent(agent)}

  def apply(%__MODULE__{} = profile, %Agent{} = agent) do
    base = base_agent(agent)

    with :ok <- check_struct(profile),
         :ok <- check_id(profile),
         {:ok, patch} <- prepare(profile, base),
         :ok <- check_manifest(profile, base, patch) do
      {:ok, patched_agent(profile, base, patch)}
    end
  end

  def apply(other, %Agent{}), do: not_a_profile(other)

  @doc "As `apply/2`, raising `Nous.Errors.ProfileError`."
  @spec apply!(t() | nil, Agent.t()) :: Agent.t()
  def apply!(profile, %Agent{} = agent) do
    case apply(profile, agent) do
      {:ok, agent} -> agent
      {:error, error} -> raise error
    end
  end

  @doc """
  Fills `profile`'s manifest with the hashes of `agent`'s base text and
  recomputes its id.

  Every check of `validate/2` but the manifest's runs first. Sealing pins a
  hand-written profile to the agent it was written for; from then on any
  change to that base text makes the profile `:stale`.
  """
  @spec seal(t(), Agent.t()) :: {:ok, t()} | {:error, ProfileError.t()}
  def seal(%__MODULE__{} = profile, %Agent{} = agent) do
    base = base_agent(agent)
    profile = %{profile | manifest: %{}, id: nil}

    with :ok <- check_struct(profile),
         {:ok, patch} <- prepare(profile, base),
         {:ok, manifest} <- base_hashes(base, patch) do
      sealed = %{profile | manifest: manifest}
      {:ok, %{sealed | id: compute_id(sealed)}}
    end
  end

  def seal(other, %Agent{}), do: not_a_profile(other)

  @doc "The id of the profile `agent` runs with, or nil."
  @spec applied_id(Agent.t()) :: String.t() | nil
  def applied_id(%Agent{profile: %Applied{profile: %__MODULE__{id: id}}}), do: id
  def applied_id(%Agent{}), do: nil

  # ── apply internals ─────────────────────────────────────────────────────────

  defp base_agent(%Agent{profile: %Applied{} = applied} = agent) do
    %{
      agent
      | instructions: applied.base_instructions,
        tools: applied.base_tools,
        profile: nil
    }
  end

  defp base_agent(%Agent{} = agent), do: agent

  # Everything but the manifest: the instruction text and the patched tools,
  # keyed by name. `tools` maps each addressed name to `{base, patched}`.
  defp prepare(profile, base) do
    keys = profile.components |> Map.keys() |> Enum.sort()

    with :ok <- check_instructions(profile, base),
         {:ok, tools} <- resolve_tools(keys, base.tools),
         {:ok, patched} <- patch_tools(keys, profile.components, tools) do
      {:ok,
       %{
         instructions: Map.get(profile.components, "instructions"),
         tools: Map.new(tools, fn {name, tool} -> {name, {tool, Map.fetch!(patched, name)}} end)
       }}
    end
  end

  defp check_instructions(%{components: %{"instructions" => _}}, base) do
    if is_function(base_instructions(base)) do
      error(
        :dynamic_instructions,
        "instructions",
        "the agent's instructions are a function; static profile text cannot replace them"
      )
    else
      :ok
    end
  end

  defp check_instructions(_profile, _base), do: :ok

  # The base slot a profile's "instructions" replaces: `instructions`, which
  # the runner prefers, else `system_prompt`.
  defp base_instructions(%Agent{instructions: nil, system_prompt: system_prompt}),
    do: system_prompt

  defp base_instructions(%Agent{instructions: instructions}), do: instructions

  defp resolve_tools(keys, tools) do
    keys
    |> Enum.flat_map(fn key ->
      case parse_key(key) do
        {:ok, {:tool, name}} -> [name]
        {:ok, {:param, name, _path}} -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_tool(name, tools) do
        {:ok, tool} -> {:cont, {:ok, Map.put(acc, name, tool)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_tool(name, tools) do
    key = "tool:" <> name

    case Enum.filter(tools, &(&1.name == name)) do
      [] ->
        error(:unknown_tool, key, "the agent has no tool named #{inspect(name)}")

      [_, _ | _] ->
        error(:ambiguous_tool, key, "the agent has several tools named #{inspect(name)}")

      [tool] ->
        if builtin?(tool),
          do: error(:builtin_tool, key, "built-in Nous tools are not addressable by a profile"),
          else: {:ok, tool}
    end
  end

  # A tool defined by Nous itself: its module (or its function's module)
  # sits under the `Nous` namespace.
  defp builtin?(%Tool{module: module, function: function}) do
    case module || function_module(function) do
      nil -> false
      mod -> elixir_module?(mod) and hd(Module.split(mod)) == "Nous"
    end
  end

  defp function_module(function) when is_function(function) do
    {:module, module} = Function.info(function, :module)
    module
  end

  defp function_module(_other), do: nil

  defp elixir_module?(module), do: match?("Elixir." <> _, Atom.to_string(module))

  # Patch the addressed tools, parameter pointers first (all of them before
  # any description, matching the documented check order).
  defp patch_tools(keys, components, tools) do
    parsed = Enum.map(keys, &{&1, elem(parse_key(&1), 1)})

    with {:ok, tools} <- patch_params(parsed, components, tools) do
      {:ok, patch_descriptions(parsed, components, tools)}
    end
  end

  defp patch_params(parsed, components, tools) do
    Enum.reduce_while(parsed, {:ok, tools}, fn
      {key, {:param, name, path}}, {:ok, acc} ->
        tool = Map.fetch!(acc, name)

        case patch_node(tool.parameters, path, Map.fetch!(components, key)) do
          {:ok, parameters} ->
            {:cont, {:ok, Map.put(acc, name, %{tool | parameters: parameters})}}

          :error ->
            {:halt,
             error(:unknown_param, key, "the pointer does not reach a schema object of the tool")}
        end

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp patch_descriptions(parsed, components, tools) do
    Enum.reduce(parsed, tools, fn
      {key, {:tool, name}}, acc ->
        Map.update!(acc, name, fn tool ->
          # A guard reads `base_description || description`, so an absent
          # base must not let the profile text through: "" stands for it.
          %{
            tool
            | description: Map.fetch!(components, key),
              base_description: tool.description || ""
          }
        end)

      _other, acc ->
        acc
    end)
  end

  defp patched_agent(profile, base, patch) do
    applied = %Applied{
      profile: profile,
      base_instructions: base.instructions,
      base_tools: base.tools
    }

    tools =
      Enum.map(base.tools, fn tool ->
        case Map.fetch(patch.tools, tool.name) do
          {:ok, {_base, patched}} -> patched
          :error -> tool
        end
      end)

    %{
      base
      | instructions: patch.instructions || base.instructions,
        tools: tools,
        profile: applied
    }
  end

  defp check_manifest(profile, base, patch) do
    with {:ok, hashes} <- base_hashes(base, patch) do
      hashes
      |> Enum.sort()
      |> Enum.find_value(:ok, fn {key, hash} ->
        case Map.fetch(profile.manifest, key) do
          {:ok, ^hash} ->
            nil

          {:ok, _other} ->
            error(:stale, key, "the agent's base text changed since the profile was made")

          :error ->
            error(:missing_manifest, key, "no manifest hash of the base; seal the profile")
        end
      end)
    end
  end

  # The manifest the bases of `patch` produce.
  defp base_hashes(base, patch) do
    instructions =
      if patch.instructions,
        do: [{"instructions", instructions_hash(base_instructions(base))}],
        else: []

    Enum.reduce_while(patch.tools, {:ok, Map.new(instructions)}, fn {name, {tool, _}},
                                                                    {:ok, acc} ->
      case tool_hash(tool) do
        {:ok, hash} ->
          {:cont, {:ok, Map.put(acc, "tool:" <> name, hash)}}

        :error ->
          {:halt, error(:invalid_value, "tool:" <> name, "the tool schema has no JSON form")}
      end
    end)
  end

  defp instructions_hash(nil), do: CanonicalJSON.digest(@nil_marker)
  defp instructions_hash(text) when is_binary(text), do: CanonicalJSON.digest(text)

  defp tool_hash(%Tool{description: description, parameters: parameters}) do
    {:ok, CanonicalJSON.hash(%{"description" => description, "parameters" => parameters})}
  rescue
    ArgumentError -> :error
  end

  # ── schema pointers ─────────────────────────────────────────────────────────

  # Sets the description of the schema node `path` reaches; `:error` when a
  # step does not exist or lands on something other than an object.
  defp patch_node(node, [], text) when is_map(node),
    do: {:ok, Map.put(node, description_key(node), text)}

  defp patch_node(node, [{"properties", name} | rest], text) when is_map(node) do
    with {:ok, props_key, props} when is_map(props) <- fetch_schema_key(node, "properties"),
         {:ok, prop_key, child} <- fetch_property(props, name),
         {:ok, child} <- patch_node(child, rest, text) do
      {:ok, Map.put(node, props_key, Map.put(props, prop_key, child))}
    else
      _ -> :error
    end
  end

  defp patch_node(node, [{keyword, index} | rest], text)
       when is_map(node) and is_integer(index) do
    with {:ok, list_key, list} when is_list(list) and index < length(list) <-
           fetch_schema_key(node, keyword),
         {:ok, child} <- patch_node(Enum.at(list, index), rest, text) do
      {:ok, Map.put(node, list_key, List.replace_at(list, index, child))}
    else
      _ -> :error
    end
  end

  defp patch_node(node, [{keyword, nil} | rest], text) when is_map(node) do
    with {:ok, child_key, child} <- fetch_schema_key(node, keyword),
         {:ok, child} <- patch_node(child, rest, text) do
      {:ok, Map.put(node, child_key, child)}
    else
      _ -> :error
    end
  end

  defp patch_node(_node, _path, _text), do: :error

  defp fetch_schema_key(node, keyword) do
    atom = Map.fetch!(@schema_keys, keyword)

    cond do
      Map.has_key?(node, keyword) -> {:ok, keyword, Map.fetch!(node, keyword)}
      Map.has_key?(node, atom) -> {:ok, atom, Map.fetch!(node, atom)}
      true -> :error
    end
  end

  defp fetch_property(props, name) do
    case Map.fetch(props, name) do
      {:ok, child} ->
        {:ok, name, child}

      :error ->
        Enum.find_value(props, :error, fn
          {key, child} when is_atom(key) -> if Atom.to_string(key) == name, do: {:ok, key, child}
          _ -> nil
        end)
    end
  end

  # The node's own key style: an atom-keyed node gets `:description`.
  defp description_key(node) do
    cond do
      Map.has_key?(node, "description") -> "description"
      Map.has_key?(node, :description) -> :description
      Enum.any?(Map.keys(node), &is_atom/1) -> :description
      true -> "description"
    end
  end

  # ── key grammar ─────────────────────────────────────────────────────────────

  # {:ok, :instructions | {:tool, name} | {:param, name, path}} | :error
  defp parse_key("instructions"), do: {:ok, :instructions}

  defp parse_key("tool:" <> rest) do
    case String.split(rest, "#", parts: 2) do
      [""] ->
        :error

      [name] ->
        {:ok, {:tool, name}}

      ["", _pointer] ->
        :error

      [name, pointer] ->
        with {:ok, path} <- parse_pointer(pointer), do: {:ok, {:param, name, path}}
    end
  end

  defp parse_key(_key), do: :error

  defp parse_pointer(""), do: {:ok, []}
  defp parse_pointer("/" <> rest), do: rest |> String.split("/") |> parse_steps([])
  defp parse_pointer(_pointer), do: :error

  defp parse_steps([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_steps(["properties", segment | rest], acc) do
    with {:ok, name} <- unescape(segment, ""), do: parse_steps(rest, [{"properties", name} | acc])
  end

  defp parse_steps([keyword | rest], acc) when keyword in ["items", "additionalProperties"],
    do: parse_steps(rest, [{keyword, nil} | acc])

  defp parse_steps([keyword, index | rest], acc) when keyword in ["anyOf", "oneOf", "allOf"] do
    if index =~ ~r/\A(0|[1-9][0-9]{0,5})\z/,
      do: parse_steps(rest, [{keyword, String.to_integer(index)} | acc]),
      else: :error
  end

  defp parse_steps(_steps, _acc), do: :error

  # RFC 6901: "~1" is "/", "~0" is "~", any other "~" is malformed.
  defp unescape("", acc), do: {:ok, acc}
  defp unescape("~0" <> rest, acc), do: unescape(rest, acc <> "~")
  defp unescape("~1" <> rest, acc), do: unescape(rest, acc <> "/")
  defp unescape("~" <> _rest, _acc), do: :error

  defp unescape(<<char::utf8, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, char::utf8>>)

  defp unescape(_invalid, _acc), do: :error

  defp reserved?(key) do
    key in @reserved_groups or Enum.any?(@reserved_prefixes, &String.starts_with?(key, &1))
  end

  # ── structural checks ───────────────────────────────────────────────────────

  defp check_marker(map) do
    case Map.fetch(map, "nous_profile") do
      {:ok, schema} when is_integer(schema) ->
        check_schema(schema)

      {:ok, other} ->
        error(:not_a_profile, "nous_profile", "expected an integer, got #{inspect(other)}")

      :error ->
        error(:not_a_profile, nil, "the \"nous_profile\" marker is missing")
    end
  end

  defp check_schema(@schema), do: :ok

  defp check_schema(schema),
    do:
      error(:unsupported_schema, nil, "schema #{inspect(schema)}; this release reads #{@schema}")

  defp check_fields(map) do
    case Enum.find(Map.keys(map), &(&1 not in @top_level_fields)) do
      nil -> :ok
      field -> error(:unknown_field, field_name(field), "not a profile field")
    end
  end

  # The on-disk components: "instructions" and "tools" (nested by name).
  defp decode_components(nil), do: {:ok, %{}}

  defp decode_components(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {"instructions", text}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, "instructions", text)}}

      {"tools", tools}, {:ok, acc} ->
        case decode_tools(tools) do
          {:ok, flat} -> {:cont, {:ok, Map.merge(acc, flat)}}
          {:error, _} = err -> {:halt, err}
        end

      {key, _value}, _acc ->
        {:halt, group_error(key)}
    end)
  end

  defp decode_components(other),
    do: error(:invalid_value, "components", "expected a map, got #{inspect(other)}")

  defp group_error(key) when is_binary(key) do
    if reserved?(key),
      do: error(:reserved_key, key, "reserved for a later profile schema"),
      else: error(:unknown_key, key, "components hold \"instructions\" and \"tools\"")
  end

  defp group_error(key), do: error(:unknown_key, inspect(key), "component keys are strings")

  defp decode_tools(%{} = tools) do
    Enum.reduce_while(tools, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case decode_tool(name, entry) do
        {:ok, flat} -> {:cont, {:ok, Map.merge(acc, flat)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp decode_tools(other),
    do:
      error(
        :invalid_value,
        "tools",
        "expected a map of tool name to entry, got #{inspect(other)}"
      )

  defp decode_tool(name, %{} = entry) when is_binary(name) and name != "" do
    key = "tool:" <> name

    cond do
      String.contains?(name, "#") ->
        error(:unknown_key, key, "a tool name containing \"#\" is not addressable")

      field = Enum.find(Map.keys(entry), &(&1 not in @tool_entry_fields)) ->
        error(
          :unknown_field,
          field_name(field),
          "tool entries hold \"description\" and \"params\""
        )

      entry == %{} ->
        error(:invalid_value, key, "the tool entry replaces nothing")

      true ->
        with {:ok, params} <- decode_params(key, Map.get(entry, "params")) do
          description = if Map.has_key?(entry, "description"), do: %{key => entry["description"]}
          {:ok, Map.merge(params, description || %{})}
        end
    end
  end

  defp decode_tool(name, _entry) when is_binary(name) and name != "",
    do: error(:invalid_value, "tool:" <> name, "expected a map with \"description\"/\"params\"")

  defp decode_tool(name, _entry),
    do: error(:unknown_key, inspect(name), "tool names are non-empty strings")

  defp decode_params(_key, nil), do: {:ok, %{}}

  defp decode_params(key, %{} = params) do
    Enum.reduce_while(params, {:ok, %{}}, fn
      {pointer, text}, {:ok, acc} when is_binary(pointer) ->
        {:cont, {:ok, Map.put(acc, key <> "#" <> pointer, text)}}

      {pointer, _text}, _acc ->
        {:halt, error(:unknown_key, key <> "#" <> inspect(pointer), "pointers are strings")}
    end)
  end

  defp decode_params(key, other),
    do: error(:invalid_value, key, "\"params\" must map pointers to text, got #{inspect(other)}")

  defp decode_manifest(nil), do: {:ok, %{}}
  defp decode_manifest(%{} = manifest), do: {:ok, manifest}

  defp decode_manifest(other),
    do: error(:invalid_value, "manifest", "expected a map, got #{inspect(other)}")

  # Everything that can be checked without an agent. Runs on every apply, so
  # a hand-built or edited struct is held to the same rules as a file.
  defp check_struct(%__MODULE__{} = profile) do
    with :ok <- check_schema(profile.schema),
         :ok <- check_meta(profile),
         :ok <- check_components(profile.components),
         :ok <- check_manifest_shape(profile.manifest, profile.components) do
      check_provenance(profile.provenance)
    end
  end

  defp check_meta(%{name: name, version: version, parent_id: parent_id, id: id}) do
    cond do
      not (is_nil(name) or (is_binary(name) and name =~ ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/)) ->
        error(
          :invalid_value,
          "name",
          "expected ~r/[a-z0-9][a-z0-9_.-]{0,63}/, got #{inspect(name)}"
        )

      not (is_nil(version) or (is_integer(version) and version > 0)) ->
        error(:invalid_value, "version", "expected a positive integer, got #{inspect(version)}")

      not (is_nil(parent_id) or hash?(parent_id)) ->
        error(:invalid_value, "parent_id", "expected \"sha256:<hex>\", got #{inspect(parent_id)}")

      not (is_nil(id) or hash?(id)) ->
        error(:invalid_value, "id", "expected \"sha256:<hex>\", got #{inspect(id)}")

      true ->
        :ok
    end
  end

  defp check_components(%{} = components) do
    components
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, text} ->
      case check_component(key, text) do
        :ok -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp check_components(other),
    do: error(:invalid_value, "components", "expected a map, got #{inspect(other)}")

  defp check_component(key, text) when is_binary(key) do
    case parse_key(key) do
      {:ok, :instructions} -> check_text(key, text, @max_instructions_bytes)
      {:ok, _tool_or_param} -> check_text(key, text, @max_description_bytes)
      :error when is_binary(key) -> key_error(key)
    end
  end

  defp check_component(key, _text),
    do: error(:unknown_key, inspect(key), "component keys are strings")

  defp key_error(key) do
    if reserved?(key),
      do: error(:reserved_key, key, "reserved for a later profile schema"),
      else:
        error(
          :unknown_key,
          key,
          "not \"instructions\", \"tool:<name>\" or \"tool:<name>#<pointer>\""
        )
  end

  defp check_text(key, text, max) when is_binary(text) do
    cond do
      not String.valid?(text) ->
        error(:invalid_value, key, "not valid UTF-8")

      String.contains?(text, <<0>>) ->
        error(:invalid_value, key, "contains a NUL byte")

      String.trim(text) == "" ->
        error(:invalid_value, key, "blank")

      byte_size(text) > max ->
        error(:invalid_value, key, "#{byte_size(text)} bytes; at most #{max}")

      true ->
        :ok
    end
  end

  defp check_text(key, other, _max),
    do: error(:invalid_value, key, "expected text, got #{inspect(other)}")

  # Manifest keys name a base ("instructions" or "tool:<name>") that some
  # component replaces; anything else would change the id without changing
  # what the profile does.
  defp check_manifest_shape(%{} = manifest, components) do
    bases = components |> Map.keys() |> Enum.map(&base_key/1) |> MapSet.new()

    manifest
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, hash} ->
      cond do
        not is_binary(key) or not MapSet.member?(bases, key) ->
          error(:unknown_key, manifest_key(key), "a manifest entry without a component")

        not hash?(hash) ->
          error(
            :invalid_value,
            "manifest." <> key,
            "expected \"sha256:<hex>\", got #{inspect(hash)}"
          )

        true ->
          nil
      end
    end)
  end

  defp check_manifest_shape(other, _components),
    do: error(:invalid_value, "manifest", "expected a map, got #{inspect(other)}")

  defp manifest_key(key) when is_binary(key), do: "manifest." <> key
  defp manifest_key(key), do: "manifest." <> inspect(key)

  defp base_key(key) do
    case parse_key(key) do
      {:ok, :instructions} -> "instructions"
      {:ok, {:tool, name}} -> "tool:" <> name
      {:ok, {:param, name, _path}} -> "tool:" <> name
      :error -> nil
    end
  end

  defp check_provenance(%{} = provenance) do
    cond do
      not json_native?(provenance) ->
        error(:invalid_value, "provenance", "must be JSON data with string keys")

      Map.has_key?(provenance, "source") and provenance["source"] not in @sources ->
        error(:invalid_value, "provenance.source", "one of #{Enum.join(@sources, ", ")}")

      not valid_note?(Map.get(provenance, "note")) ->
        error(:invalid_value, "provenance.note", "text of at most #{@max_note_chars} characters")

      true ->
        :ok
    end
  end

  defp check_provenance(other),
    do: error(:invalid_value, "provenance", "expected a map, got #{inspect(other)}")

  defp valid_note?(nil), do: true
  defp valid_note?(note) when is_binary(note), do: String.length(note) <= @max_note_chars
  defp valid_note?(_note), do: false

  defp json_native?(%{} = map) when not is_struct(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json_native?(value) end)

  defp json_native?(list) when is_list(list), do: Enum.all?(list, &json_native?/1)
  defp json_native?(value) when is_binary(value), do: String.valid?(value)

  defp json_native?(value),
    do: is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value)

  defp check_id(%__MODULE__{id: nil}), do: :ok

  defp check_id(%__MODULE__{id: id} = profile) do
    case compute_id(profile) do
      ^id -> :ok
      computed -> error(:id_mismatch, "id", "declared #{id}, content hashes to #{computed}")
    end
  end

  defp compute_id(%__MODULE__{} = profile) do
    CanonicalJSON.hash(%{
      "schema" => profile.schema,
      "components" => profile.components,
      "manifest" => profile.manifest
    })
  end

  defp hash?("sha256:" <> hex), do: byte_size(hex) == 64 and hex =~ ~r/\A[0-9a-f]+\z/
  defp hash?(_other), do: false

  # ── files ───────────────────────────────────────────────────────────────────

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, posix} -> error(:file_error, nil, "#{path}: #{:file.format_error(posix)}")
    end
  end

  defp decode_file(path, text) do
    case path |> Path.extname() |> String.downcase() do
      ".json" ->
        case JSON.decode(text) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> error(:decode_error, nil, "#{path}: #{inspect(reason)}")
        end

      ext when ext in [".yaml", ".yml"] ->
        case YamlElixir.read_from_string(text) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> error(:decode_error, nil, "#{path}: #{Exception.message(reason)}")
        end

      ext ->
        error(:decode_error, nil, "#{path}: unsupported extension #{inspect(ext)}")
    end
  end

  defp nest_components(components) do
    Enum.reduce(components, %{}, fn {key, text}, acc ->
      case parse_key(key) do
        {:ok, :instructions} ->
          Map.put(acc, "instructions", text)

        {:ok, {:tool, name}} ->
          put_tool_field(acc, name, ["description"], text)

        {:ok, {:param, name, _path}} ->
          [_tool, pointer] = String.split(key, "#", parts: 2)
          put_tool_field(acc, name, ["params", pointer], text)
      end
    end)
  end

  defp put_tool_field(acc, name, path, text) do
    tools = Map.get(acc, "tools", %{})
    entry = Map.get(tools, name, %{})
    Map.put(acc, "tools", Map.put(tools, name, put_in_path(entry, path, text)))
  end

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value),
    do: Map.put(map, key, put_in_path(Map.get(map, key, %{}), rest, value))

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp field_name(field) when is_binary(field), do: field
  defp field_name(field), do: inspect(field)

  defp not_a_profile(other),
    do: error(:not_a_profile, nil, "expected a %Nous.Profile{}, got #{inspect(other)}")

  defp error(reason, key, detail),
    do: {:error, ProfileError.exception(reason: reason, key: key, detail: detail)}
end
