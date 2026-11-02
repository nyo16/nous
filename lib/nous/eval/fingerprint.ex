defmodule Nous.Eval.Fingerprint do
  @moduledoc """
  Identifies the configuration an eval run tested.

  Two runs with equal fingerprint `"id"`s ran the same model, prompt, tools,
  guard configuration, data and scorers with the same sampling settings, so
  their results are comparable. `build/5` returns a JSON-native map (string
  keys, no atoms) that is stored on `Nous.Eval.Run` as is:

    * `"model"` - `"provider:model"`; `"model_settings"` - the agent's
      settings merged over the model's defaults
    * `"instructions"` - hash of the effective instructions (`instructions`,
      else `system_prompt`). A function is resolved once with empty deps and
      its text hashed when that succeeds; it is also identified as
      `%{"module", "name", "arity"}` for a named capture (`&Mod.fun/1`), or
      `"anonymous"` with a `Logger` warning, because an edit inside an
      anonymous function does not change its identity
    * `"tools"` - hash of the model-visible tool schemas (name, description,
      parameters), sorted by name, plus the names
    * `"guards"` - the plugin list and the guard configurations found in
      deps (`:input_guard_config`, `:decision_guard_config`,
      `:loop_guard_config`)
    * `"profile_id"` - the `Nous.Profile` the agent applies
      (`Nous.Profile.applied_id/1`; `nil` without one). The instruction and
      tool hashes above are of the applied text
    * `"dataset"` - the dataset content hash (`Nous.Eval.Dataset`)
    * `"scorers"` - each task scorer's module, options, composition and its
      `c:Nous.Eval.Scorer.describe/1` output; `"prompt_hash"` lifts a judge's
      prompt hash out of `describe/1`
    * `"k"`, `"seed"`, `"seed_forwarded"` - samples per case, base seed, and
      whether the agent's provider sends the seed on the wire (see
      `Nous.Provider`'s `seed_param/0`); without a seed it is `false`
    * `"nous_version"`, `"schema_version"` - the Nous release and the run
      record format (`Nous.Eval.Run.schema_version/0`)
    * `"task"` - the task module
    * `"simulator"` - only for a run with simulated cases: the simulated
      user's model, settings and prompt template version
      (`Nous.Eval.Simulator`)
    * `"id"` - `Nous.Eval.CanonicalJSON.hash/1` of all of the above

  Model credentials and base URLs are never part of the fingerprint.
  """

  alias Nous.Eval.{CanonicalJSON, Dataset, Run}
  alias Nous.Eval.Scorer.Spec

  require Logger

  @guard_config_keys [:input_guard_config, :decision_guard_config, :loop_guard_config]

  @doc """
  Builds the fingerprint of a run.

  ## Options

    * `:k` - samples per case (default `1`)
    * `:seed` - the run's base seed (default `nil`)
    * `:deps` - the deps the agent runs with; guard configurations are read
      from them (default `%{}`)
    * `:simulator` - the `"simulator"` entry (`nil`, the default, adds none)

  Scorers that export `describe/1` are initialized with their options to
  describe them; an `init/1` error is returned as `{:error, _}`.
  """
  @spec build(module(), Nous.Agent.t(), Dataset.t(), [Spec.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def build(task, %Nous.Agent{} = agent, %Dataset{} = dataset, scorers, opts \\ [])
      when is_atom(task) and is_list(scorers) and is_list(opts) do
    seed = Keyword.get(opts, :seed)
    deps = opts |> Keyword.get(:deps, %{}) |> Map.new()

    with {:ok, scorer_terms} <- scorer_terms(scorers) do
      fingerprint =
        agent_terms(agent)
        |> Map.merge(%{
          "task" => Atom.to_string(task),
          "guards" => guard_terms(agent, deps),
          "profile_id" => Nous.Profile.applied_id(agent),
          "dataset" => dataset.hash,
          "scorers" => scorer_terms,
          "k" => Keyword.get(opts, :k, 1),
          "seed" => seed,
          "seed_forwarded" => seed != nil and seed_forwarded?(agent.model),
          "nous_version" => nous_version(),
          "schema_version" => Run.schema_version()
        })
        |> put_simulator(Keyword.get(opts, :simulator))

      {:ok, Map.put(fingerprint, "id", CanonicalJSON.hash(fingerprint))}
    end
  end

  # Only runs with simulated cases carry the key, so every other run keeps
  # the fingerprint id it always had.
  defp put_simulator(fingerprint, nil), do: fingerprint

  defp put_simulator(fingerprint, %{} = simulator),
    do: Map.put(fingerprint, "simulator", simulator)

  @doc """
  Whether `model`'s provider sends `model_settings[:seed]` to the API.

  Read from the provider module's `seed_param/0` (`use Nous.Provider,
  seed_param: ...`). A provider without it, or one that is not loaded,
  counts as not forwarding.
  """
  @spec seed_forwarded?(Nous.Model.t()) :: boolean()
  def seed_forwarded?(%Nous.Model{provider: provider}) do
    module = Nous.ModelDispatcher.provider_module(provider)

    Code.ensure_loaded?(module) and function_exported?(module, :seed_param, 0) and
      module.seed_param() != nil
  end

  @doc false
  # Turns any term into JSON-native data (string keys, no atoms) with a stable
  # canonical encoding. Shared with `Nous.Eval.Dataset` for case content.
  # `where` names the config the term came from, for the anonymous-function
  # warning.
  @spec term(term(), String.t()) :: term()
  def term(value, where)

  def term(value, _where) when value in [nil, true, false], do: value
  def term(atom, _where) when is_atom(atom), do: Atom.to_string(atom)
  def term(number, _where) when is_number(number), do: number

  def term(binary, _where) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: %{"bytes" => Base.encode64(binary)}
  end

  def term(fun, where) when is_function(fun), do: function_term(fun, where)

  def term(%Nous.Model{} = model, where) do
    %{"model" => model_id(model), "default_settings" => term(model.default_settings, where)}
  end

  def term(%Nous.Agent{} = agent, where), do: agent_terms(agent, where)
  def term(%Nous.Tool{} = tool, where), do: tool_schema(tool, where)
  def term(%Regex{source: source, opts: opts}, _where), do: %{"regex" => source, "opts" => opts}

  def term(%module{} = struct, where) do
    %{"struct" => Atom.to_string(module), "fields" => term(Map.from_struct(struct), where)}
  end

  def term(map, where) when is_map(map) do
    if plain_keys?(Map.keys(map)) do
      Map.new(map, fn {key, value} -> {key_string(key), term(value, where)} end)
    else
      pairs(map, where)
    end
  end

  def term([], _where), do: []

  def term(list, where) when is_list(list) do
    cond do
      improper?(list) -> %{"improper_list" => inspect(list)}
      Keyword.keyword?(list) and plain_keys?(Keyword.keys(list)) -> term(Map.new(list), where)
      true -> Enum.map(list, &term(&1, where))
    end
  end

  def term(tuple, where) when is_tuple(tuple) do
    %{"tuple" => tuple |> Tuple.to_list() |> Enum.map(&term(&1, where))}
  end

  def term(pid, _where) when is_pid(pid), do: %{"opaque" => "pid"}
  def term(port, _where) when is_port(port), do: %{"opaque" => "port"}
  def term(ref, _where) when is_reference(ref), do: %{"opaque" => "reference"}

  # Keys keep their identity only when no two of them share a string form
  # (`:a` and `"a"`); otherwise the map is kept as sorted key/value pairs.
  defp plain_keys?(keys) do
    Enum.all?(keys, &(is_binary(&1) or (is_atom(&1) and &1 not in [nil, true, false]))) and
      keys |> Enum.map(&key_string/1) |> Enum.uniq() |> length() == length(keys)
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)

  defp pairs(map, where) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> [term(key, where), term(value, where)] end)
      |> Enum.sort_by(fn [key, _] -> CanonicalJSON.encode(key) end)

    %{"map" => pairs}
  end

  defp improper?([_ | tail]) when is_list(tail), do: improper?(tail)
  defp improper?([]), do: false
  defp improper?(_), do: true

  defp function_term(fun, where) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        {:module, module} = Function.info(fun, :module)
        {:name, name} = Function.info(fun, :name)
        {:arity, arity} = Function.info(fun, :arity)

        %{
          "function" => %{
            "module" => Atom.to_string(module),
            "name" => Atom.to_string(name),
            "arity" => arity
          }
        }

      {:type, :local} ->
        {:module, module} = Function.info(fun, :module)

        Logger.warning(
          "[Nous.Eval] #{where}: an anonymous function (defined in #{inspect(module)}) " <>
            "cannot be fingerprinted; editing it will not change the run fingerprint. " <>
            "Use a named capture such as &MyModule.fun/1."
        )

        %{"function" => "anonymous"}
    end
  end

  # -- Agent -------------------------------------------------------------------

  defp agent_terms(agent, where \\ "agent") do
    %{
      "model" => model_id(agent.model),
      "model_settings" =>
        term(Map.merge(agent.model.default_settings, agent.model_settings), where),
      "instructions" => instructions_term(agent.instructions || agent.system_prompt, where),
      "tools" => tools_term(agent, where)
    }
  end

  defp model_id(%Nous.Model{provider: provider, model: model}), do: "#{provider}:#{model}"

  defp instructions_term(nil, _where), do: nil

  defp instructions_term(text, _where) when is_binary(text),
    do: %{"hash" => CanonicalJSON.digest(text)}

  defp instructions_term(fun, where) when is_function(fun) do
    %{
      "function" => function_term(fun, "#{where} instructions")["function"],
      "hash" => resolved_hash(fun)
    }
  end

  # The text the function returns without deps: it stands in for the prompt
  # when the function does not need deps, and is `nil` when it raises or
  # needs them.
  defp resolved_hash(fun) when is_function(fun, 1) do
    case fun.(Nous.RunContext.new(%{})) do
      text when is_binary(text) -> CanonicalJSON.digest(text)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp resolved_hash(_fun), do: nil

  defp tools_term(agent, where) do
    schemas =
      agent
      |> visible_tools()
      |> Enum.map(&tool_schema(&1, where))
      |> Enum.sort_by(& &1["name"])

    %{"hash" => CanonicalJSON.hash(schemas), "names" => Enum.map(schemas, & &1["name"])}
  end

  # The behaviour's tool list is what the model sees (ReAct adds its own
  # tools to the agent's).
  defp visible_tools(%Nous.Agent{behaviour_module: behaviour} = agent) do
    if behaviour && Code.ensure_loaded?(behaviour) &&
         function_exported?(behaviour, :get_tools, 1),
       do: behaviour.get_tools(agent),
       else: agent.tools
  end

  defp tool_schema(%Nous.Tool{} = tool, where) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => term(tool.parameters, "#{where} tool #{inspect(tool.name)}")
    }
  end

  # -- Guards ------------------------------------------------------------------

  defp guard_terms(agent, deps) do
    config =
      for key <- @guard_config_keys, Map.has_key?(deps, key), into: %{} do
        {Atom.to_string(key), term(Map.fetch!(deps, key), "deps #{inspect(key)}")}
      end

    %{"plugins" => Enum.map(agent.plugins, &term(&1, "plugins")), "config" => config}
  end

  # -- Scorers -----------------------------------------------------------------

  defp scorer_terms(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case scorer_term(spec) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      error -> error
    end
  end

  defp scorer_term(%Spec{module: module} = spec) do
    where = "scorer #{inspect(module)}"

    with {:ok, description} <- describe(spec) do
      {:ok,
       %{
         "module" => Atom.to_string(module),
         "opts" => term(spec.opts, where),
         "required" => spec.required,
         "weight" => spec.weight,
         "skippable" => spec.skippable,
         "describe" => description && term(description, where),
         "prompt_hash" => prompt_hash(description)
       }}
    end
  end

  defp scorer_term(other), do: {:error, {:invalid_scorer, other}}

  defp describe(%Spec{module: module, opts: opts}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :describe, 1) do
      case module.init(opts) do
        {:ok, config} -> {:ok, module.describe(config)}
        {:error, reason} -> {:error, {:scorer_init_failed, module, reason}}
      end
    else
      {:ok, nil}
    end
  rescue
    exception -> {:error, {:scorer_init_failed, module, Exception.message(exception)}}
  end

  defp prompt_hash(%{} = description),
    do: Map.get(description, :prompt_hash) || Map.get(description, "prompt_hash")

  defp prompt_hash(_), do: nil

  defp nous_version do
    case Application.spec(:nous, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end
end
