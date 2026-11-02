defmodule Nous.Eval.Scorers.Function do
  @moduledoc """
  Wraps a one-argument function as a scorer, for Elixir-defined datasets
  and tasks. It cannot be referenced from YAML/JSONL files.

      {Nous.Eval.Scorers.Function,
       name: "mentions_order", fun: fn input -> input.output =~ "order" end}

  The function receives the `Nous.Eval.ScoreInput` and returns:

    * `true` / `false` - a `:pass` / `:fail` score
    * a number in `0.0..1.0` - a float score, `passed?` when at least
      `:threshold`
    * a `Nous.Eval.Score` or a list of them, or any
      `t:Nous.Eval.Scorer.result/0` (`{:ok, _}`, `{:skip, reason}`,
      `{:error, %Nous.Eval.ScorerError{}}`), passed through

  Anything else, and any number outside `0.0..1.0`, is rejected by
  `Nous.Eval.Scoring` as a scorer error.

  ## Options

    * `:fun` - the function (required)
    * `:name` - the score name (default `"function"`)
    * `:threshold` - for numeric returns (default `0.5`)
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.Options

  @id "function"

  @impl true
  def id, do: @id

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, [:fun, :name, :threshold]),
         {:ok, config} <-
           Options.parse(map, [
             {:name, @id, &Options.string(@id, :name, &1)},
             {:threshold, 0.5, &Options.unit_float(@id, :threshold, &1)}
           ]) do
      case Map.get(map, :fun) do
        fun when is_function(fun, 1) -> {:ok, Map.put(config, :fun, fun)}
        other -> Options.invalid(@id, "fun must be a 1-arity function, got #{inspect(other)}")
      end
    end
  end

  @impl true
  def score(%ScoreInput{} = input, config) do
    case config.fun.(input) do
      passed? when is_boolean(passed?) ->
        {:ok, Options.pass_fail(config.name, passed?, nil)}

      number when is_number(number) ->
        value = number / 1
        {:ok, %Score{name: config.name, value: value, passed?: value >= config.threshold}}

      %Score{} = score ->
        {:ok, score}

      [%Score{} | _] = scores ->
        {:ok, scores}

      other ->
        other
    end
  end

  @impl true
  def describe(config) do
    %{name: config.name, threshold: config.threshold, fun: describe_fun(config.fun)}
  end

  # Named captures fingerprint by identity; anonymous functions cannot.
  defp describe_fun(fun) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        info = Function.info(fun)
        %{module: info[:module], name: info[:name], arity: info[:arity]}

      {:type, :local} ->
        :anonymous
    end
  end
end
