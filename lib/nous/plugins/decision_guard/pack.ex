defmodule Nous.Plugins.DecisionGuard.Pack do
  @moduledoc """
  Behaviour for a `Nous.Plugins.DecisionGuard` question pack: the questions a
  decision model answers about one surface, the probability bands that turn
  the answers into a verdict, and the state the model sees.

  Built-in packs:

  | Pack | Surface | Event |
  |---|---|---|
  | `Nous.Plugins.DecisionGuard.Packs.UserInput` | `:user_input` | plugin `before_request/3` |
  | `Nous.Plugins.DecisionGuard.Packs.ToolCall` | `:tool_call` | `:pre_tool_use` |
  | `Nous.Plugins.DecisionGuard.Packs.ToolResult` | `:tool_result` | `:post_tool_use` |
  | `Nous.Plugins.DecisionGuard.Packs.ModelOutput` | `:model_output` | `:post_response` |

  ## Model families

  Prompts and thresholds do not transfer between decision-model families
  (Red Hat measured a policy tuned for one family costing another several
  points). Every pack declares the family it was tuned on (`model_family/0`,
  `"clef"` for the built-ins, covering Clef and Clef-Flash), and `bands/1`
  **refuses** to hand out default bands for any other family: pass `:bands`
  for every question instead.

  ## Questions and bands

  Questions are an ordered keyword list (Clef decides them jointly, in
  order). Every risk question is phrased so that the risky answer reads high
  (`"true"` for a `:noul`). Bands are `Nous.Hook.Decision` bands:
  `{allow_below, deny_at}`.
  """

  alias Nous.DecisionModel
  alias Nous.DecisionModel.Question

  @type surface :: :user_input | :tool_call | :tool_result | :model_output
  @type verdict :: Nous.Hook.Decision.verdict()

  @doc "The surface this pack guards."
  @callback surface() :: surface()

  @doc "The decision-model family the questions and bands were tuned on."
  @callback model_family() :: String.t()

  @doc """
  The questions, in order. `opts[:include]` switches on opt-in groups (see
  each pack).
  """
  @callback questions(opts :: keyword()) :: [{atom(), keyword()}]

  @doc """
  Default bands for `questions(opts)`, keyed by question id. `opts[:preset]`
  selects a preset; `opts[:model_family]` must equal `model_family/0` (see
  `ensure_family!/2`), or this raises `ArgumentError`.
  """
  @callback bands(opts :: keyword()) :: %{atom() => term()}

  @doc """
  The state the decision model sees: a JSON-framed map whose keys sort with
  `"untrusted_content"` last. `payload` is the hook payload (`%{content: text}`
  on the user-input surface); `env` is `t:Nous.Hook.Decision.env/0`.
  """
  @callback state(payload :: map(), env :: map()) :: term()

  @doc """
  Optional cross-question rule, run per chunk after the bands. It can only
  raise the verdict. See `Nous.Hook.Decision` (`:combine`).
  """
  @callback combine(answers :: %{atom() => DecisionModel.Answer.t()}, verdict()) :: verdict()

  @optional_callbacks combine: 2

  @doc """
  Raises `ArgumentError` unless `opts[:model_family]` is `pack`'s family.
  Packs call it from `bands/1`.
  """
  @spec ensure_family!(module(), keyword()) :: :ok
  def ensure_family!(pack, opts) do
    family = pack.model_family()

    case Keyword.get(opts, :model_family) do
      ^family ->
        :ok

      nil ->
        raise ArgumentError,
              "#{inspect(pack)}: cannot tell the decision model's family. Set :model_family " <>
                "(default bands exist only for #{inspect(family)}) or pass :bands for every question"

      other ->
        raise ArgumentError,
              "#{inspect(pack)} has no default bands for model family #{inspect(other)}: its " <>
                "prompts and thresholds were tuned on #{inspect(family)} and do not transfer. " <>
                "Pass :bands for every question"
    end
  end

  @doc """
  The decision model's family: `opts[:model_family]` when given, else
  `"clef"` when the model name contains "clef", else `nil`.
  """
  @spec model_family(DecisionModel.t(), keyword()) :: String.t() | nil
  def model_family(%DecisionModel{model: model}, opts) do
    case Keyword.get(opts, :model_family) do
      family when is_binary(family) ->
        family

      nil ->
        if is_binary(model) and String.contains?(String.downcase(model), "clef"),
          do: "clef",
          else: nil
    end
  end

  @doc """
  A `%Nous.DecisionModel{}` from a struct or a `Nous.DecisionModel.parse/2`
  string.
  """
  @spec resolve_model!(DecisionModel.t() | String.t()) :: DecisionModel.t()
  def resolve_model!(%DecisionModel{} = dm), do: dm
  def resolve_model!(model) when is_binary(model), do: DecisionModel.parse(model)

  def resolve_model!(other),
    do:
      raise(
        ArgumentError,
        ":model must be a %Nous.DecisionModel{} or a decision-model string, got: #{inspect(other)}"
      )

  @doc """
  Resolves `pack`'s questions, bands and combine rule against user overrides,
  as `Nous.Hook.Decision.new/1` options (`:questions`, `:bands`, `:combine`).

  `opts`:

    * `:questions` - `nil` (the pack's), `{:replace, questions}` or
      `{:extend, questions}` (appended after the pack's).
    * `:bands` - `%{id => band}`; wins over the pack's. When every question
      has one, the pack's defaults are not consulted (so another family
      works); otherwise they are, and `bands/1` refuses a foreign family.
    * `:preset`, `:include`, `:model_family` - passed to the pack.

  The pack's `combine/2` applies only to its own (not replaced) questions on
  its own family.
  """
  @spec build(module(), keyword()) :: keyword()
  def build(pack, opts) do
    {questions, replaced?} =
      case Keyword.get(opts, :questions) do
        nil ->
          {pack.questions(opts), false}

        {:replace, questions} ->
          {questions, true}

        {:extend, questions} ->
          {pack.questions(opts) ++ questions, false}

        other ->
          raise ArgumentError,
                ":questions must be {:replace, questions} or {:extend, questions}, got: " <>
                  inspect(other)
      end

    ids = questions |> Question.normalize!() |> Enum.map(& &1.id)
    user_bands = Map.new(Keyword.get(opts, :bands) || %{})

    defaults =
      if Enum.all?(ids, &Map.has_key?(user_bands, &1)),
        do: %{},
        else: pack.bands(opts)

    combine =
      if not replaced? and Keyword.get(opts, :model_family) == pack.model_family() and
           Code.ensure_loaded?(pack) and function_exported?(pack, :combine, 2),
         do: &pack.combine/2

    [
      questions: questions,
      bands: defaults |> Map.take(ids) |> Map.merge(user_bands),
      combine: combine
    ]
  end
end
