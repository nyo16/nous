defmodule Nous.Router do
  @moduledoc """
  Pre-dispatch model routing: pick the chat model for a request before it is
  built.

  A router is configured on the agent as `{module, opts}`, next to
  `:fallback`, because both are model-selection concerns:

      agent =
        Nous.new("anthropic:claude-sonnet-4-5",
          fallback: ["openai:gpt-4o"],
          router:
            {Nous.Router.DecisionModel,
             model: Nous.DecisionModel.parse("workers_ai:clef-flash"),
             tiers: [
               simple: [model: "groq:llama-3.1-8b-instant", description: "small talk, lookups, arithmetic"],
               complex: [model: "anthropic:claude-sonnet-4-5", description: "multi-step reasoning, code, proofs"]
             ]}
        )

  `Nous.run/3` also accepts `router:` as a per-run override (`router: nil`
  turns routing off for that run). `Nous.Router.DecisionModel` is the shipped
  implementation; any module implementing this behaviour works.

  ## When the router is asked

  The `:granularity` option (read from the router's opts, for every router)
  sets the routing boundaries:

    * `:per_turn` (default) - the first request of every turn. A turn is one
      `Nous.run/3` / `Nous.AgentRunner.run_with_context/3` call, plus one per
      structured-output validation retry.
    * `:once` - the first request of the run only.
    * `:per_iteration` - every request, including the ones that follow tool
      results. Most decision calls and most prompt-cache misses.
    * `:escalate_only` - every request, but the model only ever moves **up**
      the router's ordered tiers (`c:tiers/1`, cheapest first, required for
      this mode). The run starts on the cheapest tier; a decision for a lower
      or equal tier, `:default` or an error keeps the current one, and once
      the top tier is reached the router is no longer asked.

  The decision is runtime-only: it is never written to `result.deps` or to a
  persisted context, so every run (and every `Nous.AgentServer` turn) routes
  afresh.

  ## Fallback interplay

  A routed request uses the chain `[routed | agent.fallback]` (deduplicated),
  with tool schemas and structured-output settings built for the routed
  model's provider. `[:nous, :agent, :fallback, :used]` fires only when a
  model other than the routed one answered. A fallback that answered stays
  sticky until the next routing boundary, where the new decision clears it.

  `:default` (or `{:default, meta}`), an `{:error, reason}`, an invalid
  return value or a raise all mean "no route": the request goes to
  `agent.model` (except under `:escalate_only`, which keeps its current
  tier). Under `:escalate_only`, a `c:tiers/1` that raises or returns
  anything but a non-empty list of `%Nous.Model{}` fails `new/1`; if it
  does so later, during a run, that request is not routed (current tier, or
  `agent.model` before the first decision). Routing fails open by design; a
  router is a cost/latency control, not a security control.

  ## Not routed

  `Nous.run_stream/3` (`Nous.AgentRunner.run_stream/3`) is a single request
  whose consumer owns the stream and is **never routed**: it always uses
  `agent.model` and its fallback chain. Use `Nous.run/3` with `stream: true`
  for a routed, streamed run.

  ## Telemetry

    * `[:nous, :router, :route]` - once per router consultation
      * Measurements: `%{duration: native_time}` (the router call's latency)
      * Metadata: `%{agent_name, router, granularity, turn, iteration, cause,
        tier, probabilities, confidence, reason, model_provider, model_name}`.
        `cause` is `:routed`, `:held` (`:escalate_only` kept its tier),
        `:default`, `:error`, or the `:cause` a router put in its meta (e.g.
        `:low_confidence`). `model_provider` / `model_name` name the model the
        requests now go to.

  ## Writing a router

      defmodule MyApp.LengthRouter do
        @behaviour Nous.Router

        @impl true
        def init(opts), do: Keyword.update!(opts, :long, &Nous.Model.parse/1)

        @impl true
        def route(_agent, %{text: text}, opts) do
          if String.length(text) > 2_000,
            do: {:ok, opts[:long], %{tier: :long}},
            else: :default
        end
      end

      Nous.new("openai:gpt-4o-mini", router: {MyApp.LengthRouter, long: "openai:gpt-4o"})

  `c:init/1` runs once when the agent is built (and for a per-run `router:`
  override) and must be idempotent: a spec that already went through it may
  be passed through it again.
  """

  alias Nous.{Agent, Model}

  @granularities [:once, :per_turn, :per_iteration, :escalate_only]

  @typedoc "When the router is consulted. See the module docs."
  @type granularity :: :once | :per_turn | :per_iteration | :escalate_only

  @typedoc """
  What the router sees for the request being built:

    * `:text` - the latest user message's text (`""` when there is none)
    * `:messages` - the conversation so far
    * `:iteration` - the run's iteration counter (0 for its first request)
    * `:turn` - the turn index in the session log (1-based)
    * `:granularity` - the configured granularity
    * `:current_model` - the routed model in effect, or `nil` before the
      first decision of the run (or after a `:default`)
  """
  @type info :: %{
          text: String.t(),
          messages: [Nous.Message.t()],
          iteration: non_neg_integer(),
          turn: pos_integer(),
          granularity: granularity(),
          current_model: Model.t() | nil
        }

  @typedoc """
  Optional decision details, surfaced in `[:nous, :router, :route]`: `:tier`,
  `:probabilities`, `:confidence`, and for `{:default, meta}` a `:cause` and
  `:reason`.
  """
  @type meta :: map()

  @type decision ::
          {:ok, Model.t()}
          | {:ok, Model.t(), meta()}
          | :default
          | {:default, meta()}
          | {:error, term()}

  @typedoc "A router spec: the module and its (normalised) options."
  @type t :: {module(), keyword()}

  @doc "Chooses the model for the request described by `info`."
  @callback route(agent :: Agent.t(), info :: info(), opts :: keyword()) :: decision()

  @doc """
  Validates and normalises the options once, when the agent is built. Must be
  idempotent. Raise `ArgumentError` for invalid options.
  """
  @callback init(opts :: keyword()) :: keyword()

  @doc """
  The router's models in order, cheapest first. Required by
  `granularity: :escalate_only`.
  """
  @callback tiers(opts :: keyword()) :: [Model.t()]

  @optional_callbacks init: 1, tiers: 1

  @doc """
  Validates a router spec and runs the module's `c:init/1`.

  Accepts `nil`, a module, or `{module, opts}`. Raises `ArgumentError` when the
  module does not implement `c:route/3`, the granularity is unknown, or
  `:escalate_only` is asked of a router without `c:tiers/1` or whose
  `c:tiers/1` does not return a non-empty list of `%Nous.Model{}`.
  """
  @spec new(t() | module() | nil) :: t() | nil
  def new(nil), do: nil

  def new(module) when is_atom(module), do: new({module, []})

  def new({module, opts}) when is_atom(module) and is_list(opts) do
    unless exported?(module, :route, 3) do
      raise ArgumentError, "#{inspect(module)} does not implement Nous.Router (route/3)"
    end

    opts = if exported?(module, :init, 1), do: module.init(opts), else: opts
    granularity = granularity(opts)

    unless granularity in @granularities do
      raise ArgumentError,
            "invalid router granularity #{inspect(granularity)}, expected one of " <>
              inspect(@granularities)
    end

    if granularity == :escalate_only, do: validate_tiers!(module, opts)

    {module, opts}
  end

  def new(other) do
    raise ArgumentError, "router must be nil, a module or {module, opts}, got: #{inspect(other)}"
  end

  @doc false
  # The router's ordered tiers, checked: a non-empty list of `%Nous.Model{}`.
  # A raise, an exit or any other return is `{:error, reason}`, so the runner
  # can fail open on it.
  @spec tiers(module(), keyword()) :: {:ok, [Model.t(), ...]} | {:error, term()}
  def tiers(module, opts) do
    case module.tiers(opts) do
      [_ | _] = tiers ->
        if Enum.all?(tiers, &match?(%Model{}, &1)),
          do: {:ok, tiers},
          else: {:error, {:invalid_tiers, tiers}}

      other ->
        {:error, {:invalid_tiers, other}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp validate_tiers!(module, opts) do
    unless exported?(module, :tiers, 1) do
      raise ArgumentError,
            "granularity: :escalate_only needs ordered tiers, but #{inspect(module)} " <>
              "does not implement tiers/1"
    end

    case tiers(module, opts) do
      {:ok, _tiers} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "granularity: :escalate_only needs a non-empty list of %Nous.Model{} from " <>
                "#{inspect(module)}.tiers/1, got: #{inspect(reason)}"
    end
  end

  @doc "The configured granularity (default `:per_turn`)."
  @spec granularity(keyword()) :: granularity() | term()
  def granularity(opts) when is_list(opts), do: Keyword.get(opts, :granularity, :per_turn)

  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
