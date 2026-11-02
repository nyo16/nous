defmodule Nous.Eval.Guard.Subject do
  @moduledoc """
  The guard under calibration: a DecisionGuard surface or an InputGuard
  strategy ensemble, resolved from the same configuration the plugin reads.

      Nous.Eval.Guard.Subject.new({:decision_guard, %{model: dm}}, :user_input)
      Nous.Eval.Guard.Subject.new({:input_guard, %{strategies: [...]}}, :user_input)

  A DecisionGuard subject holds the `Nous.Hook.Decision` the plugin builds for
  the surface (`Nous.Plugins.DecisionGuard.decision/2`), whether the
  `Pattern` ensemble runs beside it (user input), the per-call timeout and
  `:on_error`. An InputGuard subject holds the strategy list, `:aggregation`
  and `:fail_closed`; it guards `:user_input` only.

  ## Guard inputs from cases

  `state/3` builds what the guard classifies from a classifier case's
  `input`, mirroring the runner's payloads: a `tool_call` case becomes a
  `:pre_tool_use` payload (`tool_name`, `arguments`), a `tool_result` case a
  `:post_tool_use` payload (plus `result`), a `model_output` case a
  `:post_response` payload (`content`, `tool_calls`); `task` is the env's
  task. When a case has no `tool.description`, the description comes from
  the `:tools` given (the agent under test's tools; a `Nous.Tool`'s
  developer description, as the guard itself reads it, or a `name =>
  description` map). A user-input case is classified on its text plus its
  `text/*` attachments, as `Nous.Plugins.InputGuard.Engine.message_text/2`
  renders them.
  """

  alias Nous.Eval.CanonicalJSON
  alias Nous.Eval.Guard.{Case, Hygiene}
  alias Nous.Hook.Decision
  alias Nous.Plugins.DecisionGuard

  @events %{
    tool_call: :pre_tool_use,
    tool_result: :post_tool_use,
    model_output: :post_response
  }

  @type kind :: :decision_guard | :input_guard

  @type t :: %__MODULE__{
          kind: kind(),
          surface: Case.surface(),
          decision: Decision.t() | nil,
          pattern_ensemble: boolean(),
          timeout: non_neg_integer() | :infinity,
          on_error: :allow | :escalate | :deny,
          strategies: [{module(), keyword()}],
          aggregation: :any | :majority | :all,
          fail_closed: boolean(),
          config: map()
        }

  @enforce_keys [:kind, :surface]
  defstruct [
    :kind,
    :surface,
    :decision,
    pattern_ensemble: false,
    timeout: 10_000,
    on_error: :deny,
    strategies: [],
    aggregation: :any,
    fail_closed: true,
    config: %{}
  ]

  @doc """
  Resolves `{:decision_guard, config}` (a `:decision_guard_config`) or
  `{:input_guard, config}` (an `:input_guard_config`) for `surface`.
  Returns `{:error, message}` on an invalid configuration.
  """
  @spec new({kind(), map() | keyword()} | t(), Case.surface()) ::
          {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{surface: surface} = subject, surface), do: {:ok, subject}

  def new({:decision_guard, config}, surface)
      when (is_map(config) or is_list(config)) and
             surface in [:user_input, :tool_call, :tool_result, :model_output] do
    settings = DecisionGuard.surface_settings(config, surface)

    {:ok,
     %__MODULE__{
       kind: :decision_guard,
       surface: surface,
       decision: settings.decision,
       pattern_ensemble: settings.pattern_ensemble,
       timeout: settings.timeout,
       on_error: settings.on_error,
       config: Map.new(config)
     }}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  def new({:input_guard, config}, :user_input) when is_map(config) or is_list(config) do
    config = Map.new(config)

    with {:ok, strategies} <- strategies(Map.get(config, :strategies)),
         {:ok, aggregation} <-
           member(Map.get(config, :aggregation, :any), [:any, :majority, :all], :aggregation),
         {:ok, fail_closed} <-
           member(Map.get(config, :fail_closed, true), [true, false], :fail_closed) do
      {:ok,
       %__MODULE__{
         kind: :input_guard,
         surface: :user_input,
         strategies: strategies,
         aggregation: aggregation,
         fail_closed: fail_closed,
         timeout: Map.get(config, :strategy_timeout, 30_000),
         config: config
       }}
    end
  end

  def new({:input_guard, _config}, surface),
    do: {:error, "an InputGuard guards :user_input only, not #{inspect(surface)}"}

  def new(other, surface),
    do:
      {:error,
       "expected {:decision_guard, config} or {:input_guard, config} for #{inspect(surface)}, got: " <>
         inspect(other)}

  defp strategies([_ | _] = list) do
    if Enum.all?(list, &match?({mod, opts} when is_atom(mod) and is_list(opts), &1)),
      do: {:ok, list},
      else: {:error, ":strategies must be a list of {module, keyword} tuples"}
  end

  defp strategies(other),
    do: {:error, ":strategies must be a non-empty list, got: #{inspect(other)}"}

  defp member(value, allowed, key) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "#{inspect(key)} must be one of #{inspect(allowed)}, got: #{inspect(value)}"}
  end

  @doc """
  What the subject classifies for `case`: `{:text, text}` on user input,
  else `{:state, state}` (the decision model's state, built by the decision's
  state builder). See the moduledoc for `tools`.
  """
  @spec state(t(), Case.t(), [Nous.Tool.t()] | %{String.t() => String.t()}) ::
          {:text, String.t()} | {:state, term()}
  def state(%__MODULE__{surface: :user_input}, %Case{} = c, _tools),
    do: {:text, Hygiene.canonical_text(c)}

  def state(%__MODULE__{decision: %Decision{} = d, surface: surface}, %Case{input: input}, tools) do
    event = Map.fetch!(@events, surface)
    env = %{approval_handler: nil, agent_name: nil, task: input["task"], tool: tool(input, tools)}
    payload = payload(surface, input)

    state =
      case d.state do
        nil -> Decision.default_state(event, payload, env)
        builder -> builder.(payload, env)
      end

    {:state, state}
  end

  defp payload(:tool_call, input),
    do: %{tool_name: input["tool"]["name"], tool_id: "guard-case", arguments: input["arguments"]}

  defp payload(:tool_result, input) do
    %{
      tool_name: input["tool"]["name"],
      tool_id: "guard-case",
      arguments: Map.get(input, "arguments", %{}),
      result: input["result"]
    }
  end

  defp payload(:model_output, input),
    do: %{content: input["content"], tool_calls: Map.get(input, "tool_calls", [])}

  defp tool(%{"tool" => %{"name" => name} = tool}, tools) do
    %{
      name: name,
      description: Map.get(tool, "description") || description(tools, name),
      category: Map.get(tool, "category")
    }
  end

  defp tool(_input, _tools), do: nil

  defp description(tools, name) when is_map(tools), do: Map.get(tools, name)

  defp description(tools, name) when is_list(tools) do
    Enum.find_value(tools, fn
      %Nous.Tool{name: ^name} = t -> t.base_description || t.description
      _ -> nil
    end)
  end

  @doc """
  `"sha256:<hex>"` of everything that decides what the subject's model is
  asked (not the bands, which only replay reads): two subjects with equal
  recording fingerprints over the same cases and tools give the same
  recording, so the second is served from the cache.
  """
  @spec recording_fingerprint(t(), [Case.t()], term()) :: String.t()
  def recording_fingerprint(%__MODULE__{} = s, cases, tools) do
    CanonicalJSON.hash(%{
      "kind" => Atom.to_string(s.kind),
      "surface" => Atom.to_string(s.surface),
      "model" => model_identity(s),
      "pattern_ensemble" => s.pattern_ensemble,
      "cases" => cases |> Enum.map(&[&1.id, Case.content_sha256(&1)]) |> Enum.sort(),
      "tools" => tools_identity(tools),
      "nous_version" => to_string(Application.spec(:nous, :vsn))
    })
  end

  defp model_identity(%__MODULE__{kind: :decision_guard, decision: d}) do
    %{
      "backend" => inspect(d.model.backend),
      "model" => to_string(d.model.model),
      "opts" => inspect(d.model.opts, limit: :infinity),
      "questions" => inspect(d.questions, limit: :infinity),
      "state" => inspect(d.state),
      "oversize" => Atom.to_string(d.oversize),
      "max_chunks" => d.max_chunks,
      "canary" => d.canary
    }
  end

  defp model_identity(%__MODULE__{kind: :input_guard, strategies: strategies}),
    do: %{"strategies" => inspect(strategies, limit: :infinity)}

  defp tools_identity(tools) when is_map(tools),
    do: tools |> Enum.sort() |> Enum.map(&Tuple.to_list/1)

  defp tools_identity(tools) when is_list(tools) do
    tools
    |> Enum.flat_map(fn
      %Nous.Tool{} = t -> [[t.name, t.base_description || t.description]]
      _ -> []
    end)
    |> Enum.sort()
  end

  defp tools_identity(_), do: []
end
