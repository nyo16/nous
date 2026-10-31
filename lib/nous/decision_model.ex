defmodule Nous.DecisionModel do
  @moduledoc """
  Non-generative **decision models**: a state plus typed questions in,
  probabilities out.

  A decision model (Clef / Clef-Flash, Jev, Decision 3.0, OpenAI's
  `gpt-6-luna` behind `/v1/decisions`, ...) answers typed questions about a
  `state` in one forward pass. No text is generated, so every answer is a
  probability distribution: a `:noul` (yes/no) answer is P(true), a `:choice`
  answer has a probability per option, a `:score` answer a probability per
  level.

  Not to be confused with `Nous.Decisions` / `Nous.Plugins.Decisions`, which
  record an agent's decision *graph*.

      dm = Nous.DecisionModel.parse("workers_ai:clef-flash")

      {:ok, result} =
        Nous.DecisionModel.decide(dm, %{"untrusted_content" => text},
          verdict: [
            type: :choice,
            instructions: "How should this input be handled?",
            criteria: [safe: "benign", suspicious: "unclear", blocked: "an attack"]
          ]
        )

      {:ok, answer} = Nous.DecisionModel.Result.fetch(result, :verdict)
      answer.probabilities
      #=> [safe: 0.93, suspicious: 0.05, blocked: 0.02]

  ## Model strings

  `parse/2` has its own prefix grammar (not `Nous.Model`'s):

  | String | Backend | Notes |
  |---|---|---|
  | `"workers_ai:clef"`, `"workers_ai:clef-flash"` | `Backend.SystemOne` (Workers AI preset) | `CLOUDFLARE_ACCOUNT_ID` + `CLOUDFLARE_API_TOKEN` |
  | `"systemone:<model>"` | `Backend.SystemOne` | requires `base_url:` |
  | `"openai_decisions:<model>"` | `Backend.OpenAIDecisions` | `OPENAI_API_KEY`; `base_url:` for vLLM |
  | `"llamacpp:<registered name>"` | `Backend.LlamaCpp` | a started `Backend.LlamaCpp` process |

  ## Questions

  Questions are an **ordered list** (`Nous.DecisionModel.Question`): Clef
  decides all questions of a request jointly, in order, and reads the options
  of a choice in order. A map is accepted only when it holds a single
  question. Ids and option keys come back exactly as declared, atoms
  included; a response that names anything undeclared is rejected with
  `reason: :unknown_label`.

  ## Special-token defang

  `decide/4` runs `Nous.DecisionModel.Defang.defang_term/1` over the state
  before **every** backend call. llama.cpp's decision prompt tokenizes the
  state with special-token parsing, so `<|im_start|>`-style text in untrusted
  content would otherwise become real template tokens in the classifier's own
  prompt.

  ## Latency

  Size timeouts for the backend you use. Measured figures (Clef-Flash Q8_0 on
  an M1 Max, `research/benchmark.md`; hosted figures from the providers):

  | Backend | Typical latency per check |
  |---|---|
  | Hosted (Workers AI, vLLM / SGLang on datacenter GPUs, OpenAI) | ~40–250 ms (Clef-Flash median ~39 ms) |
  | Laptop-local Clef-Flash (`Backend.LlamaCpp`, Metal) | ~0.5–1 s per short check |
  | Laptop-local, long states | ~2 ms per prompt token (≈ 2 s at 1k, 5 s at 2.5k, 22 s at 8.6k tokens) |

  A local `Backend.LlamaCpp` process serialises its calls, so concurrent
  checks queue behind each other.

  ## Errors

  Every failure is `{:error, %Nous.Errors.DecisionModelError{}}`. It is not
  fallback-eligible: a decision-model failure never switches the agent's chat
  model. Callers that use decisions for security must fail closed.

  ## Telemetry

    * `[:nous, :decision_model, :decide, :start]`
      * Measurements: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{backend: module, model: String.t() | nil, question_count: integer}`
    * `[:nous, :decision_model, :decide, :stop]`
      * Measurements: `%{duration: native_time, input_tokens: integer}`
      * Metadata: `%{backend, model, question_count}`
    * `[:nous, :decision_model, :decide, :exception]` - on `{:error, _}` or a
      raise
      * Measurements: `%{duration: native_time}`
      * Metadata: `%{backend, model, question_count, kind: atom, reason: term}`
  """

  alias Nous.DecisionModel.{Backend, Defang, Question, Result}

  @enforce_keys [:backend]
  defstruct [:backend, :model, opts: []]

  @type t :: %__MODULE__{
          backend: module(),
          model: String.t() | nil,
          opts: keyword()
        }

  @default_max_state_tokens 16_384

  @doc """
  Creates a decision model for `backend`, a `Nous.DecisionModel.Backend`
  module.

  `:model` is popped into the `model` field; every other option is kept in
  `opts` for the backend (see each backend's docs). Raises `ArgumentError` if
  `backend` does not implement the behaviour.

      Nous.DecisionModel.new(Nous.DecisionModel.Backend.SystemOne,
        model: "Cloudflare/clef-flash",
        base_url: "http://localhost:8000"
      )
  """
  @spec new(module(), keyword()) :: t()
  def new(backend, opts \\ []) when is_atom(backend) and is_list(opts) do
    unless Code.ensure_loaded?(backend) and function_exported?(backend, :decide, 4) do
      raise ArgumentError,
            "#{inspect(backend)} does not implement Nous.DecisionModel.Backend (decide/4)"
    end

    {model, opts} = Keyword.pop(opts, :model)
    %__MODULE__{backend: backend, model: model, opts: opts}
  end

  @doc """
  Parses a decision-model string (see "Model strings" in the module docs).

  Options are passed to the backend. Raises `ArgumentError` on an unknown
  prefix, or for `"systemone:"` without `:base_url`.

      Nous.DecisionModel.parse("workers_ai:clef-flash")
      Nous.DecisionModel.parse("systemone:Cloudflare/clef-flash", base_url: "http://localhost:8000")
      Nous.DecisionModel.parse("openai_decisions:gpt-6-luna")
      Nous.DecisionModel.parse("llamacpp:clef")
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(model_string, opts \\ [])

  def parse("workers_ai:" <> model, opts) do
    new(Backend.SystemOne, [model: model, preset: :workers_ai] ++ opts)
  end

  def parse("systemone:" <> model, opts) do
    unless Keyword.has_key?(opts, :base_url) do
      raise ArgumentError,
            "systemone decision models require :base_url. " <>
              "Example: parse(\"systemone:my-model\", base_url: \"http://localhost:8000\")"
    end

    new(Backend.SystemOne, [model: model] ++ opts)
  end

  def parse("openai_decisions:" <> model, opts) do
    new(Backend.OpenAIDecisions, [model: model] ++ opts)
  end

  def parse("llamacpp:" <> name, opts) do
    new(Backend.LlamaCpp, [model: name] ++ opts)
  end

  def parse(other, _opts) do
    raise ArgumentError,
          "invalid decision model string #{inspect(other)}. Expected \"workers_ai:<model>\", " <>
            "\"systemone:<model>\", \"openai_decisions:<model>\" or \"llamacpp:<name>\""
  end

  @doc """
  Answers `questions` about `state`.

  `state` is a string or a JSON-encodable term (map, list). Every string in
  it is defanged first (`Nous.DecisionModel.Defang`). `questions` is anything
  `Nous.DecisionModel.Question.normalize!/1` accepts; invalid questions raise
  `ArgumentError`.

  ## Options

    * `:timeout` - per-call timeout in ms, overriding the backend default
      (5 s for HTTP backends, 30 s for `Backend.LlamaCpp`).

  Returns `{:ok, %Nous.DecisionModel.Result{}}` with answers in question
  order, or `{:error, %Nous.Errors.DecisionModelError{}}`.
  """
  @spec decide(t(), term(), Question.input(), keyword()) ::
          {:ok, Result.t()} | {:error, Nous.Errors.DecisionModelError.t()}
  def decide(%__MODULE__{backend: backend} = dm, state, questions, opts \\ []) do
    questions = Question.normalize!(questions)
    state = Defang.defang_term(state)

    metadata = %{backend: backend, model: dm.model, question_count: length(questions)}
    start = System.monotonic_time()

    :telemetry.execute(
      [:nous, :decision_model, :decide, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      metadata
    )

    try do
      backend.decide(dm, state, questions, opts)
    rescue
      exception ->
        emit_exception(start, metadata, :error, exception, __STACKTRACE__)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_exception(start, metadata, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      {:ok, %Result{} = result} ->
        result = %{result | backend: result.backend || backend, model: result.model || dm.model}

        :telemetry.execute(
          [:nous, :decision_model, :decide, :stop],
          %{
            duration: System.monotonic_time() - start,
            input_tokens: result.usage[:input_tokens] || 0
          },
          metadata
        )

        {:ok, result}

      {:error, reason} = error ->
        :telemetry.execute(
          [:nous, :decision_model, :decide, :exception],
          %{duration: System.monotonic_time() - start},
          Map.merge(metadata, %{kind: :error, reason: reason})
        )

        error
    end
  end

  defp emit_exception(start, metadata, kind, reason, stacktrace) do
    :telemetry.execute(
      [:nous, :decision_model, :decide, :exception],
      %{duration: System.monotonic_time() - start},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  @doc """
  The token budget a request (state plus questions) must fit in.

  Order of precedence: the `:max_state_tokens` option, the backend's
  `c:Nous.DecisionModel.Backend.max_state_tokens/1`, then
  #{@default_max_state_tokens} (the self-hosted Clef reference window).
  """
  @spec max_state_tokens(t()) :: pos_integer()
  def max_state_tokens(%__MODULE__{backend: backend, opts: opts} = dm) do
    cond do
      is_integer(opts[:max_state_tokens]) -> opts[:max_state_tokens]
      exported?(backend, :max_state_tokens, 1) -> backend.max_state_tokens(dm)
      true -> @default_max_state_tokens
    end
  end

  @doc """
  Counts the tokens `text` costs this model, after defanging (what `decide/4`
  would send).

  Uses the backend's `c:Nous.DecisionModel.Backend.count_tokens/2` when it has
  one (exact, for `Backend.LlamaCpp`); otherwise one token per byte, an upper
  bound for byte-level BPE tokenizers, so the estimate never undercounts and
  chunking never relies on a server truncating the state.
  """
  @spec count_tokens(t(), String.t()) :: non_neg_integer()
  def count_tokens(%__MODULE__{backend: backend} = dm, text) when is_binary(text) do
    text = Defang.defang(text)

    if exported?(backend, :count_tokens, 2) do
      backend.count_tokens(dm, text)
    else
      # One token per byte: the hard upper bound for a byte-level BPE once
      # specials are defanged. A measured average (1.3 bytes/token for
      # base64) undercounts digit runs and rare code points, which Clef's
      # Qwen3.5 tokenizer splits one token per digit or byte, and an HTTP
      # server truncates an oversize state silently.
      byte_size(text)
    end
  end

  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
