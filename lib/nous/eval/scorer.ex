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
  call a model as `:model_graded`. `option_keys/0` (optional) lists the
  options a dataset file (YAML/JSONL) may set; a scorer without it cannot be
  configured from a file. `init/1` must accept the string forms of its
  enum-valued options (`"superset"` for `:superset`), because file values
  are never turned into atoms.

  ## Referencing scorers from dataset files

  YAML and JSONL name scorers by string, resolved with `resolve/2` through
  a fixed table of built-ins plus the application's own table:

      config :nous, :eval_scorers, %{"house_style" => MyApp.Eval.HouseStyle}

  An unknown name or option is an error; nothing in a file becomes an atom.
  """

  alias Nous.Eval.{Score, ScoreInput, ScorerError}

  @type result :: {:ok, Score.t() | [Score.t()]} | {:skip, String.t()} | {:error, ScorerError.t()}

  @callback id() :: String.t()
  @callback init(opts :: keyword()) :: {:ok, config :: term()} | {:error, term()}
  @callback score(ScoreInput.t(), config :: term()) :: result()
  @callback describe(config :: term()) :: map()
  @callback kind() :: :deterministic | :model_graded
  @callback option_keys() :: [atom()]

  @optional_callbacks [describe: 1, kind: 0, option_keys: 0]

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

  @builtin %{
    "equals" => Nous.Eval.Scorers.Equals,
    "similarity" => Nous.Eval.Scorers.Similarity,
    "contains" => Nous.Eval.Scorers.Contains,
    "not_contains" => Nous.Eval.Scorers.NotContains,
    "regex" => Nous.Eval.Scorers.Regex,
    "output_schema" => Nous.Eval.Scorers.OutputSchema,
    "trajectory" => Nous.Eval.Scorers.Trajectory,
    "tool_args" => Nous.Eval.Scorers.ToolArgs,
    "tool_count" => Nous.Eval.Scorers.ToolCount,
    "no_tool_errors" => Nous.Eval.Scorers.NoToolErrors,
    "guard_verdict" => Nous.Eval.Scorers.GuardVerdict,
    "max_cost" => Nous.Eval.Scorers.MaxCost,
    "max_latency" => Nous.Eval.Scorers.MaxLatency,
    "max_tokens" => Nous.Eval.Scorers.MaxTokens,
    "output_retries" => Nous.Eval.Scorers.OutputRetries,
    "judge" => Nous.Eval.Scorers.Judge
  }

  # Composition keys every declaration may carry, next to the scorer's own
  # options.
  @spec_keys %{"required" => :required, "weight" => :weight, "skippable" => :skippable}

  @doc """
  Resolves a scorer named in a dataset file into a `Spec`.

  `name` is looked up in the built-in table, then in
  `config :nous, :eval_scorers`. `opts` is the string-keyed map from the
  file: `"required"`, `"weight"` and `"skippable"` set the composition,
  every other key must be one of the scorer's `c:option_keys/0`. Option
  values are passed through unchanged; the scorer's `c:init/1` validates
  them.
  """
  @spec resolve(String.t(), map()) :: {:ok, Spec.t()} | {:error, String.t()}
  def resolve(name, opts \\ %{}) when is_binary(name) and is_map(opts) do
    with {:ok, module} <- lookup(name),
         {:ok, allowed} <- allowed_keys(name, module),
         {:ok, composition, scorer_opts} <- split_opts(name, opts, allowed),
         :ok <- validate_composition(name, composition) do
      {:ok, struct!(Spec, [module: module, opts: scorer_opts] ++ composition)}
    end
  end

  defp lookup(name) do
    table = Map.merge(@builtin, Application.get_env(:nous, :eval_scorers, %{}))

    case Map.fetch(table, name) do
      {:ok, module} when is_atom(module) -> {:ok, module}
      _ -> {:error, "unknown scorer #{inspect(name)}"}
    end
  end

  defp allowed_keys(name, module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :option_keys, 0) do
      {:ok, Map.new(module.option_keys(), &{Atom.to_string(&1), &1})}
    else
      {:error, "scorer #{inspect(name)} cannot be configured from a dataset file"}
    end
  end

  defp split_opts(name, opts, allowed) do
    opts
    |> Enum.reduce_while({:ok, [], []}, fn {key, value}, {:ok, composition, scorer_opts} ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, "scorer #{inspect(name)}: option keys must be strings"}}

        Map.has_key?(@spec_keys, key) ->
          {:cont, {:ok, [{@spec_keys[key], value} | composition], scorer_opts}}

        Map.has_key?(allowed, key) ->
          {:cont, {:ok, composition, [{allowed[key], value} | scorer_opts]}}

        true ->
          {:halt, {:error, "scorer #{inspect(name)}: unknown option #{inspect(key)}"}}
      end
    end)
    |> case do
      {:ok, composition, scorer_opts} -> {:ok, Enum.reverse(composition), Enum.sort(scorer_opts)}
      error -> error
    end
  end

  defp validate_composition(name, composition) do
    Enum.reduce_while(composition, :ok, fn
      {key, value}, :ok when key in [:required, :skippable] and is_boolean(value) ->
        {:cont, :ok}

      {:weight, value}, :ok when is_number(value) and value >= 0 ->
        {:cont, :ok}

      {key, value}, :ok ->
        {:halt, {:error, "scorer #{inspect(name)}: invalid #{key} #{inspect(value)}"}}
    end)
  end
end
