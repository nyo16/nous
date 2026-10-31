defmodule Nous.Router.DecisionModel do
  @moduledoc """
  A `Nous.Router` that asks a `Nous.DecisionModel` (Clef, Clef-Flash, ...)
  which model tier should answer, LiteLLM-style.

      dm = Nous.DecisionModel.parse("workers_ai:clef-flash")

      agent =
        Nous.new("openai:gpt-4o",
          router:
            {Nous.Router.DecisionModel,
             model: dm,
             tiers: [
               simple: [model: "openai:gpt-4o-mini", description: "greetings, lookups, short factual answers"],
               complex: [model: "openai:gpt-4o", description: "multi-step reasoning, code, proofs, planning"]
             ],
             min_confidence: 0.6}
        )

  Each routing decision is **one** `:choice` question whose options are the
  tiers, over a JSON-framed state: `%{"latest_user_message" => text}`, plus
  `"previous_user_messages"` when `:context_turns` is above 0. The state is
  defanged by `Nous.DecisionModel.decide/4`. The decision model's answer is
  mapped back through the declared tier keys; nothing from the backend is
  turned into an atom.

  ## Options

    * `:model` - required. A `Nous.DecisionModel` struct or a decision-model
      string for `Nous.DecisionModel.parse/1`.
    * `:tiers` - required, at least two, as an ordered keyword list (or list
      of `{key, value}` with string keys), **cheapest first**: that order is
      what `granularity: :escalate_only` climbs. Keys are option ids (atoms or
      strings, `[A-Za-z0-9_.-]`). A value is one of:
      * a model string or a `Nous.Model` struct
      * a keyword list with `:model` (string or `%Nous.Model{}`), an optional
        `:description` (what the tier is for; the decision model reads it,
        default: the key) and any `Nous.Model.parse/2` options for that tier
        (`base_url:`, `api_key:`, `llamacpp_model:`, ...). Strings are parsed
        with `Nous.Fallback.parse_fallback_models/2`, so per-tier options ride
        along.
    * `:min_confidence` - 0.0 to 1.0 (default `0.0`). A decision below it is
      `{:default, %{cause: :low_confidence}}`: the agent's own model answers.
      The answer's `confidence`, or its top probability when the backend
      reports none.
    * `:granularity` - see `Nous.Router` (default `:per_turn`).
    * `:context_turns` - how many earlier user messages to include in the
      state (default `0`). More context costs decision latency.
    * `:instructions` - replaces the default routing question.
    * `:timeout` - per-decision timeout in ms, passed to
      `Nous.DecisionModel.decide/4`.

  ## Failure

  A decision-model error (timeout, oversize state, backend down) returns
  `{:default, %{cause: :error, reason: error}}`: the request goes to the
  agent's own model. Routing fails open by design. A request with no user
  text is not decided (`cause: :no_input`).
  """

  @behaviour Nous.Router

  alias Nous.{DecisionModel, Fallback, Message, Model}
  alias Nous.DecisionModel.{Answer, Question, Result}

  @question_id :route

  @default_instructions "Which model tier should answer latest_user_message? " <>
                          "Pick the cheapest tier that can answer it fully and correctly; " <>
                          "pick a stronger tier only when the request needs it."

  @impl Nous.Router
  def init(opts) when is_list(opts) do
    dm = decision_model!(Keyword.get(opts, :model))
    tiers = tiers!(Keyword.get(opts, :tiers))
    min_confidence = Keyword.get(opts, :min_confidence, 0.0)
    context_turns = Keyword.get(opts, :context_turns, 0)
    instructions = Keyword.get(opts, :instructions, @default_instructions)

    unless is_number(min_confidence) and min_confidence >= 0 and min_confidence <= 1 do
      raise ArgumentError,
            ":min_confidence must be between 0 and 1, got: #{inspect(min_confidence)}"
    end

    unless is_integer(context_turns) and context_turns >= 0 do
      raise ArgumentError,
            ":context_turns must be a non-negative integer, got: #{inspect(context_turns)}"
    end

    # Fail at configuration time, not on the first request, for a tier key or
    # instructions the decision model would reject.
    _ = Question.normalize!(question(tiers, instructions))

    Keyword.merge(opts,
      model: dm,
      tiers: tiers,
      min_confidence: min_confidence,
      context_turns: context_turns,
      instructions: instructions
    )
  end

  @impl Nous.Router
  def tiers(opts) do
    opts |> init() |> Keyword.fetch!(:tiers) |> Enum.map(fn {_key, tier} -> tier.model end)
  end

  @impl Nous.Router
  def route(_agent, %{text: text} = info, opts) do
    opts = init(opts)

    if String.trim(text) == "" do
      {:default, %{cause: :no_input}}
    else
      decide(info, opts)
    end
  end

  defp decide(info, opts) do
    tiers = Keyword.fetch!(opts, :tiers)
    decide_opts = Keyword.take(opts, [:timeout])

    with {:ok, result} <-
           DecisionModel.decide(
             Keyword.fetch!(opts, :model),
             state(info, Keyword.fetch!(opts, :context_turns)),
             question(tiers, Keyword.fetch!(opts, :instructions)),
             decide_opts
           ),
         {:ok, %Answer{} = answer} <- Result.fetch(result, @question_id) do
      pick(answer, tiers, Keyword.fetch!(opts, :min_confidence))
    else
      {:error, reason} -> {:default, %{cause: :error, reason: reason}}
      :error -> {:default, %{cause: :error, reason: :missing_answer}}
    end
  end

  defp pick(%Answer{choice: choice, probabilities: probabilities} = answer, tiers, min_confidence) do
    confidence = answer.confidence || top_probability(probabilities)

    meta = %{
      tier: choice,
      probabilities: probabilities,
      confidence: confidence
    }

    # Map the label back through the declared keys only.
    case Enum.find(tiers, fn {key, _tier} ->
           key == choice or Question.key_string(key) == choice
         end) do
      nil ->
        {:default, Map.merge(meta, %{cause: :error, reason: :unknown_tier})}

      {_key, _tier} when confidence < min_confidence ->
        {:default, Map.put(meta, :cause, :low_confidence)}

      {key, tier} ->
        {:ok, tier.model, %{meta | tier: key}}
    end
  end

  defp top_probability([]), do: 0.0
  defp top_probability(probabilities), do: probabilities |> Enum.map(&elem(&1, 1)) |> Enum.max()

  # JSON-framed: user text only ever appears as a JSON string value, never as
  # part of the question.
  defp state(%{text: text}, 0), do: %{"latest_user_message" => text}

  defp state(%{text: text, messages: messages}, context_turns) do
    previous =
      messages
      |> Enum.filter(&match?(%Message{role: :user}, &1))
      |> Enum.map(&Message.extract_text/1)
      |> Enum.drop(-1)
      |> Enum.take(-context_turns)

    %{"latest_user_message" => text, "previous_user_messages" => previous}
  end

  defp question(tiers, instructions) do
    [
      {@question_id,
       [
         type: :choice,
         instructions: instructions,
         criteria: Enum.map(tiers, fn {key, tier} -> {key, tier.description} end)
       ]}
    ]
  end

  # ── option normalisation (idempotent) ──────────────────────────────────────

  defp decision_model!(%DecisionModel{} = dm), do: dm
  defp decision_model!(string) when is_binary(string), do: DecisionModel.parse(string)

  defp decision_model!(other) do
    raise ArgumentError,
          "Nous.Router.DecisionModel needs :model, a Nous.DecisionModel or a decision-model " <>
            "string, got: #{inspect(other)}"
  end

  defp tiers!([_, _ | _] = tiers), do: Enum.map(tiers, &tier!/1)

  defp tiers!(other) do
    raise ArgumentError,
          "Nous.Router.DecisionModel needs :tiers, an ordered list of at least two " <>
            "{key, model} pairs (cheapest first), got: #{inspect(other)}"
  end

  defp tier!({key, %{model: %Model{}, description: description} = tier})
       when is_binary(description),
       do: {key, tier}

  defp tier!({key, %Model{} = model}), do: {key, %{model: model, description: default(key)}}
  defp tier!({key, model}) when is_binary(model), do: tier!({key, [model: model]})

  defp tier!({key, opts}) when is_list(opts) do
    {spec, opts} = Keyword.pop(opts, :model)
    {description, opts} = Keyword.pop(opts, :description)

    unless is_binary(spec) or is_struct(spec, Model) do
      raise ArgumentError,
            "router tier #{inspect(key)} needs :model (a model string or %Nous.Model{}), " <>
              "got: #{inspect(spec)}"
    end

    [model] = Fallback.parse_fallback_models([spec], opts)
    {key, %{model: model, description: description || default(key)}}
  end

  defp tier!(other) do
    raise ArgumentError,
          "invalid router tier #{inspect(other)}; expected {key, model_string | %Nous.Model{} | keyword}"
  end

  defp default(key) when is_atom(key) or is_binary(key), do: Question.key_string(key)

  defp default(key) do
    raise ArgumentError, "router tier keys must be atoms or strings, got: #{inspect(key)}"
  end
end
