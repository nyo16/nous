defmodule Nous.Plugins.InputGuard.Strategies.DecisionModel do
  @moduledoc """
  Decision-model input classification strategy.

  Asks a `Nous.DecisionModel` (Clef / Clef-Flash and friends) the
  `Nous.Plugins.DecisionGuard.Packs.UserInput` question - one `:choice`
  between `safe`, `suspicious` and `blocked` - about the input, framed as
  `%{"surface" => "user_input", "untrusted_content" => input}`. No text is
  generated, so there is no verdict line to forge: the answer is a
  probability distribution, and the band reads P(suspicious) + P(blocked).

  | Band verdict | Severity |
  |---|---|
  | allow | `:safe` |
  | escalate | `:suspicious` |
  | deny | `:blocked` |

  On the benchmark (326 prompts, Clef-Flash Q8_0 in-process on an M1 Max) it
  matched a local LLM judge's accuracy (0.853) with higher precision (0.947
  vs 0.855) at ~0.56 s p50 per check. See the guide for the trade-offs.

  `Nous.Plugins.DecisionGuard` runs this strategy (with
  `Nous.Plugins.InputGuard.Strategies.Pattern` under `:any`) on its
  user-input surface; it also works as a plain `Nous.Plugins.InputGuard`
  strategy.

  ## Configuration

    * `:model` — **Required.** A `%Nous.DecisionModel{}` or a
      `Nous.DecisionModel.parse/2` string (e.g. `"workers_ai:clef-flash"`).
    * `:model_family` — the model's family. Inferred as `"clef"` when the
      model name contains "clef"; the pack refuses default bands for any
      other family (pass `:bands` then).
    * `:preset` — `:balanced` (default, 0.3 / 0.7) or `:strict`
      (0.06 / 0.53). See `Nous.Plugins.DecisionGuard.Packs.UserInput`.
    * `:questions` — `{:replace, questions}` or `{:extend, questions}`.
    * `:bands` — `%{question_id => band}`, overriding the preset.
    * `:include` — opt-in question groups (`[:content_safety]`).
    * `:canary` — `true` adds a separate canary call per chunk (see
      `Nous.Hook.Decision`). Default `false`.
    * `:oversize` / `:max_chunks` — as in `Nous.Hook.Decision` (default
      `:chunk`, 8).
    * `:timeout` — per decision-model call, in ms. Default `10_000`.
    * `:on_error` — what happens when the model cannot produce a verdict
      (error, timeout, missing answer, a raise or an exit such as a
      llama.cpp process that is down), as in
      `Nous.Plugins.InputGuard.Strategies.LLMJudge`:
        * `:drop` (default) — return `{:error, reason}`; InputGuard counts
          the strategy as dropped, which under `:any` fails closed
          (`:suspicious`).
        * `:safe` — fail **open**. Explicit opt-in.
        * `:suspicious` / `:blocked` — return a verdict of that severity.
    * `:on_verdict` — optional `(info -> any)`, called after every check with
      `%{verdict, probabilities, chunk_count, canary_failed, error}`.

  ## Example

      {Nous.Plugins.InputGuard.Strategies.DecisionModel,
        model: "workers_ai:clef-flash",
        on_error: :blocked}

  Results carry `metadata: %{probabilities, chunk_count, canary_failed, why}`;
  an `:on_error` verdict carries `metadata: %{error: reason}`.
  """

  @behaviour Nous.Plugins.InputGuard.Strategy

  require Logger

  alias Nous.Hook.Decision
  alias Nous.Plugins.DecisionGuard.Pack
  alias Nous.Plugins.DecisionGuard.Packs.UserInput
  alias Nous.Plugins.InputGuard.Result

  @default_on_error :drop
  @severity %{allow: :safe, escalate: :suspicious, deny: :blocked}

  @impl true
  def check(input, config, _ctx) do
    on_error = Keyword.get(config, :on_error, @default_on_error)
    decision = decision(config)
    state = UserInput.state(%{content: input}, %{})

    case Decision.verdict(decision, state, timeout: Keyword.get(config, :timeout, 10_000)) do
      {:ok, verdict, info} ->
        report(config, verdict, info, nil)
        severity = Map.fetch!(@severity, verdict)

        {:ok,
         %Result{
           severity: severity,
           reason: reason(severity, info.why),
           strategy: __MODULE__,
           metadata: info
         }}

      {:error, reason, info} ->
        report(config, nil, info, reason)
        error_result(on_error, reason)
    end
  rescue
    e -> failed(config, Exception.message(e))
  catch
    # An exit (the llama.cpp process down or still loading, a GenServer call
    # timing out while counting tokens) is a decision-model error like any
    # other: it follows :on_error instead of escaping as a dropped strategy.
    kind, reason -> failed(config, {kind, reason})
  end

  defp failed(config, reason) do
    report(config, nil, %{probabilities: %{}, chunk_count: 0, canary_failed: 0}, reason)
    error_result(Keyword.get(config, :on_error, @default_on_error), reason)
  end

  defp decision(config) do
    dm = Pack.resolve_model!(Keyword.fetch!(config, :model))
    pack_opts = Keyword.put(config, :model_family, Pack.model_family(dm, config))

    Decision.new(
      [
        model: dm,
        oversize: Keyword.get(config, :oversize, :chunk),
        max_chunks: Keyword.get(config, :max_chunks, 8),
        canary: Keyword.get(config, :canary, false)
      ] ++ Pack.build(UserInput, pack_opts)
    )
  end

  defp reason(:safe, _why), do: nil
  defp reason(severity, :canary), do: "decision model: #{severity} (canary check failed)"

  defp reason(severity, :oversize),
    do: "decision model: #{severity} (input too large to classify fully)"

  defp reason(severity, _why), do: "decision model: #{severity}"

  defp report(config, verdict, info, error) do
    case Keyword.get(config, :on_verdict) do
      fun when is_function(fun, 1) ->
        fun.(%{
          verdict: verdict,
          probabilities: info.probabilities,
          chunk_count: info.chunk_count,
          canary_failed: info.canary_failed,
          error: error
        })

      _ ->
        :ok
    end
  rescue
    e -> Logger.warning("InputGuard.DecisionModel: on_verdict raised: #{Exception.message(e)}")
  catch
    kind, reason ->
      Logger.warning("InputGuard.DecisionModel: on_verdict #{kind}: #{inspect(reason)}")
  end

  # `:drop` hands the failure to the engine, whose dropped-strategy accounting
  # decides (fail closed under :any). Anything else is a verdict the operator
  # explicitly asked for in place of one.
  defp error_result(:drop, reason) do
    Logger.warning("InputGuard.DecisionModel: no verdict: #{inspect(reason)}; strategy dropped")
    {:error, reason}
  end

  defp error_result(on_error, reason) when on_error in [:safe, :suspicious, :blocked] do
    Logger.warning("InputGuard.DecisionModel: no verdict: #{inspect(reason)}")

    {:ok,
     %Result{
       severity: on_error,
       reason: "decision model error (fail-#{on_error})",
       strategy: __MODULE__,
       metadata: %{error: reason}
     }}
  end
end
