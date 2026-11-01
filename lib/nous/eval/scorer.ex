defmodule Nous.Eval.Scorer do
  @moduledoc """
  Behaviour for eval scorers.

  A scorer turns one sample (`Nous.Eval.ScoreInput`) into one or more
  `Nous.Eval.Score`s, a skip, or an error:

    * `{:ok, score | [score]}` - a verdict
    * `{:skip, reason}` - the scorer does not apply to this sample; excluded
      from its metrics. A required scorer may only skip when declared
      `skippable: true`, otherwise the skip is an `:invalid_config` error
    * `{:error, %Nous.Eval.ScorerError{}}` - the instrument failed

  `init/1` runs once per eval run and validates options; unknown options
  are an error. Scorers run under a supervisor with a time limit: a raise
  or timeout becomes a `Nous.Eval.ScorerError` and never discards another
  scorer's result.

  `describe/1` (optional) returns the configuration that identifies the
  scorer in the run fingerprint (for an LLM judge: model, prompt hash,
  scale). `kind/0` (optional, default `:deterministic`) marks scorers that
  call a model as `:model_graded`.
  """

  alias Nous.Eval.{Score, ScoreInput, ScorerError}

  @type result :: {:ok, Score.t() | [Score.t()]} | {:skip, String.t()} | {:error, ScorerError.t()}

  @callback id() :: String.t()
  @callback init(opts :: keyword()) :: {:ok, config :: term()} | {:error, term()}
  @callback score(ScoreInput.t(), config :: term()) :: result()
  @callback describe(config :: term()) :: map()
  @callback kind() :: :deterministic | :model_graded

  @optional_callbacks [describe: 1, kind: 0]

  defmodule Spec do
    @moduledoc """
    A scorer as declared on a task or case.

      * `:module` - the `Nous.Eval.Scorer` implementation
      * `:opts` - passed to `c:Nous.Eval.Scorer.init/1`
      * `:required` - a gate: the sample fails when it fails (default `true`)
      * `:weight` - weight in the soft group's mean when not required;
        `0` tracks the metric without affecting the verdict (default `1`)
      * `:skippable` - a required scorer may skip (default `false`)
    """

    @type t :: %__MODULE__{
            module: module(),
            opts: keyword(),
            required: boolean(),
            weight: number(),
            skippable: boolean()
          }

    @enforce_keys [:module]
    defstruct [:module, opts: [], required: true, weight: 1, skippable: false]
  end
end
