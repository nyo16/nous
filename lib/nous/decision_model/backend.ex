defmodule Nous.DecisionModel.Backend do
  @moduledoc """
  Behaviour for decision-model backends, the extension point behind
  `Nous.DecisionModel`.

  A backend turns a state and an ordered list of `Nous.DecisionModel.Question`
  into a `Nous.DecisionModel.Result`. Nous ships three:

    * `Nous.DecisionModel.Backend.SystemOne` - HTTP `/v1/systemone` (vLLM,
      SGLang, llama-server, Jev, LiteLLM) and the Cloudflare Workers AI preset
    * `Nous.DecisionModel.Backend.OpenAIDecisions` - HTTP `/v1/decisions`
      (OpenAI, vLLM)
    * `Nous.DecisionModel.Backend.LlamaCpp` - in-process `LlamaCppEx.Decision`

  ## Contract

  `c:decide/4` receives the `Nous.DecisionModel` struct (so it can read
  `model` and `opts`), the state, the validated questions and per-call opts.
  By the time it is called, `Nous.DecisionModel.decide/4` has already
  normalised the questions and defanged every string in the state; it also
  emits the telemetry events. A backend must:

    * keep question order and option order on the wire
    * map answers back through the **declared** ids and option keys, never by
      creating atoms from the response, and return
      `{:error, %Nous.Errors.DecisionModelError{reason: :unknown_label}}` when
      the response names an id, option or level that was not declared
    * return every answer in question order (`Result.answers`)
    * return `{:error, %Nous.Errors.DecisionModelError{}}` for every failure;
      never answer a failed request with probabilities

  HTTP backends go through `Nous.Providers.HTTP.post/4` and validate their
  URL with `Nous.UrlGuard`.

  ## Optional callbacks

    * `c:max_state_tokens/1` - the token budget a request (state plus
      questions) must fit in. Without it, `Nous.DecisionModel.max_state_tokens/1`
      returns a default.
    * `c:count_tokens/2` - exact token count for a text. Without it,
      `Nous.DecisionModel.count_tokens/2` assumes one token per byte.
    * `c:child_spec/1` - for backends that own a process (a loaded model).

  ## Example

      defmodule MyApp.KeywordBackend do
        @behaviour Nous.DecisionModel.Backend

        alias Nous.DecisionModel.{Answer, Result}

        @impl true
        def decide(dm, state, questions, _opts) do
          answers =
            Enum.map(questions, fn %{id: id, type: :noul} ->
              p = if String.contains?(inspect(state), "ignore previous"), do: 0.99, else: 0.01
              {id, %Answer{type: :noul, noul: p, probabilities: [{"true", p}, {"false", 1 - p}]}}
            end)

          {:ok, %Result{answers: answers, backend: __MODULE__, model: dm.model}}
        end
      end
  """

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Question, Result}
  alias Nous.Errors.DecisionModelError

  @doc """
  Answers `questions` about `state`.

  `state` is already defanged and the questions are already validated and in
  declared order. `opts` carries per-call options such as `:timeout` (ms).

  Returns `{:ok, %Nous.DecisionModel.Result{}}` with one answer per question,
  in question order, keyed by the declared ids. Every failure, including a
  response that names an undeclared id, option or level, is
  `{:error, %Nous.Errors.DecisionModelError{}}`.
  """
  @callback decide(DecisionModel.t(), state :: term(), [Question.t()], keyword()) ::
              {:ok, Result.t()} | {:error, DecisionModelError.t()}

  @doc """
  The token budget a single request (state plus questions) must fit in.

  Optional. `Nous.DecisionModel.max_state_tokens/1` prefers a
  `:max_state_tokens` option on the struct, then this callback, then a default.
  Hooks and guards size their chunks from this value.
  """
  @callback max_state_tokens(DecisionModel.t()) :: pos_integer()

  @doc """
  The exact number of tokens `text` occupies for this backend's model.

  Optional. `text` is already defanged. Without this callback,
  `Nous.DecisionModel.count_tokens/2` assumes one token per byte, an upper
  bound, so chunking never relies on server-side truncation.
  """
  @callback count_tokens(DecisionModel.t(), String.t()) :: non_neg_integer()

  @doc """
  A child spec for backends that own a process, such as a loaded local model.

  Optional. Start the child under your own supervision tree; see
  `Nous.DecisionModel.Backend.LlamaCpp` for the options it accepts.
  """
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @optional_callbacks max_state_tokens: 1, count_tokens: 2, child_spec: 1

  @doc """
  Builds a `Nous.Errors.DecisionModelError` for `backend`.

  `fields` takes `:status`, `:retryable?`, `:retry_after_ms` and `:details`.
  `:retryable?` defaults to `true` for `:timeout` and `:backend_dead`, `false`
  otherwise.
  """
  @spec error(module(), DecisionModelError.reason(), String.t(), keyword()) ::
          DecisionModelError.t()
  def error(backend, reason, message, fields \\ []) do
    DecisionModelError.exception(
      reason: reason,
      backend: backend,
      message: message,
      status: Keyword.get(fields, :status),
      retryable?: Keyword.get(fields, :retryable?, reason in [:timeout, :backend_dead]),
      retry_after_ms: Keyword.get(fields, :retry_after_ms),
      details: Keyword.get(fields, :details)
    )
  end
end
