defmodule Nous.Eval.Scorers.Trajectory do
  @moduledoc """
  Compares the tool calls in a sample's trace with an expected trajectory.

      {Nous.Eval.Scorers.Trajectory,
       expected: [
         %{name: "search_orders", args: %{"order_id" => "123"}},
         %{name: "issue_refund"},                  # any arguments
         %{name: "notify", count: {1, 2}}          # one or two calls
       ],
       mode: :superset,
       forbid: ["delete_all"]}

  ## Expected entries

  Each entry is a map with `name` (required), `args` (a map, or `:any`;
  absent means any arguments) and `count` (`n`, `{min, max}`, `[min, max]`
  or `%{"min" => _, "max" => _}`; default 1). Matching is multiset: two
  `search` entries need two `search` calls.

  ## Modes

  | Mode | Passes when |
  |---|---|
  | `:superset` (default) | every expected call was made; extra calls allowed |
  | `:subset` | every call made was expected; expected calls may be missing |
  | `:unordered` | the calls are exactly the expected multiset, in any order |
  | `:in_order` | the expected calls appear in order; other calls may be interleaved |
  | `:strict` | the calls are exactly the expected ones, in order |

  Order-free modes use a maximum bipartite matching, so a wildcard entry
  listed before a specific one never steals the call only the specific
  entry could match. Ordered modes use a dynamic program. Calls the model
  requested in one response (one batch, which may run in parallel) are
  compared order-free within the batch; `parallel: :as_emitted` compares
  them in emitted order.

  ## Options

    * `:expected` - the entries (required; may be empty only for `:strict`,
      `:unordered` and `:subset`, or with `:forbid`)
    * `:mode` - see above (default `:superset`)
    * `:args` - `:subset` (default; recursive for maps, positional for
      lists), `:exact`, `:ignore`, or a function `(actual, expected ->
      boolean)` (Elixir only)
    * `:args_overrides` - per-tool `args` mode, or a list of the only keys to
      compare: `%{"issue_refund" => :exact, "search" => ["order_id"]}`
    * `:ignore_args` - top-level argument keys dropped on both sides; `*`
      globs (`"*_cursor"`)
    * `:arg_defaults` - per-tool defaults stripped when equal:
      `%{"search" => %{"page" => 1}}`
    * `:numbers` - `:exact` (`==`, so `1` matches `1.0`; default) or
      `{:tolerance, abs: a, rel: r}` (`%{"tolerance" => %{"abs" => a}}` in
      files)
    * `:include` - which call outcomes count (default `[:executed]`; `:all`
      or a list, see `Nous.Eval.Trace.ToolCall`)
    * `:scope` - `:root` (default), `:tree` or `{:sub_agent, template}`
      (`%{"sub_agent" => template}` in files)
    * `:forbid` - tool names that fail the sample when called at all, in
      any outcome (an attempt counts even if a hook denied it)
    * `:parallel` - `:unordered_within_batch` (default) or `:as_emitted`
    * `:score` - `:binary` (default; value `:pass | :fail`) or `:f1` (a
      float: 1/0 for `:strict`, F1 of precision and recall for `:in_order`
      and `:unordered`, recall for `:superset`, precision for `:subset`;
      `0.0` on a forbidden call). `passed?` follows the mode either way.

  Enum values may be given as strings (`"in_order"`) in dataset files.

  ## Truncated traces

  When the trace was truncated, a result that depends on calls being
  absent (a failure, `:strict`/`:unordered`/`:subset`, or `:forbid`) is a
  `:missing_trace` error rather than a verdict.

  ## Details

  `matched` (`%{expected: index, tool_call_id: id}`), `missing` (expected
  entries short of calls), `unexpected` (calls no entry matched),
  `out_of_order` (ordered modes: missing entries that a call did match, out
  of order), `arg_mismatches` (`%{expected:, tool_call_id:, paths:}`, the
  argument paths that differ for the nearest same-name call) and
  `forbidden`.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Scorers.{Args, Options}
  alias Nous.Eval.Scorers.Trajectory.Matcher

  @id "trajectory"
  @modes [:strict, :in_order, :unordered, :subset, :superset]
  @option_keys [
    :expected,
    :mode,
    :args,
    :args_overrides,
    :ignore_args,
    :arg_defaults,
    :numbers,
    :include,
    :scope,
    :forbid,
    :parallel,
    :score
  ]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, entries} <- entries(Map.get(map, :expected)),
         {:ok, config} <-
           Options.parse(map, [
             {:mode, :superset, &Options.enum(@id, :mode, &1, @modes)},
             {:args, :subset, &Args.parse_mode(@id, :args, &1)},
             {:args_overrides, nil, &Args.parse_overrides(@id, &1)},
             {:ignore_args, nil, &Args.parse_ignore(@id, &1)},
             {:arg_defaults, nil, &Args.parse_defaults(@id, &1)},
             {:numbers, :exact, &Args.parse_numbers(@id, &1)},
             {:include, [:executed], &Options.include(@id, &1)},
             {:scope, :root, &Options.scope(@id, &1)},
             {:forbid, [], &forbid/1},
             {:parallel, :unordered_within_batch,
              &Options.enum(@id, :parallel, &1, [:unordered_within_batch, :as_emitted])},
             {:score, :binary, &Options.enum(@id, :score, &1, [:binary, :f1])}
           ]),
         :ok <- check_empty(entries, config) do
      {:ok, Map.put(config, :expected, entries)}
    end
  end

  defp forbid([]), do: {:ok, []}
  defp forbid(names), do: Options.string_list(@id, :forbid, names)

  defp check_empty([], %{mode: mode, forbid: []}) when mode in [:superset, :in_order],
    do: Options.invalid(@id, "expected must not be empty in #{mode} mode (it would always pass)")

  defp check_empty(_entries, _config), do: :ok

  defp entries(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case entry(entry, index) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp entries(other),
    do: Options.invalid(@id, "expected must be a list of entries, got #{inspect(other)}")

  @entry_keys %{"name" => :name, "args" => :args, "count" => :count}

  defp entry(%{} = raw, index) do
    fields =
      Enum.reduce_while(raw, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case entry_key(k) do
          {:ok, key} -> {:cont, {:ok, Map.put(acc, key, v)}}
          :error -> {:halt, Options.invalid(@id, "expected[#{index}]: unknown key #{inspect(k)}")}
        end
      end)

    with {:ok, fields} <- fields,
         {:ok, name} <- Options.string(@id, "expected[#{index}].name", Map.get(fields, :name)),
         {:ok, args} <- entry_args(Map.get(fields, :args, :any), index),
         {:ok, {min, max}} <- count(Map.get(fields, :count, 1), index) do
      {:ok, %{index: index, name: name, args: args, min: min, max: max}}
    end
  end

  defp entry(other, index),
    do: Options.invalid(@id, "expected[#{index}] must be a map, got #{inspect(other)}")

  defp entry_key(k) when is_atom(k), do: entry_key(Atom.to_string(k))
  defp entry_key(k) when is_map_key(@entry_keys, k), do: {:ok, Map.fetch!(@entry_keys, k)}
  defp entry_key(_k), do: :error

  defp entry_args(args, _index) when args in [:any, "any", nil], do: {:ok, :any}
  defp entry_args(%{} = args, _index), do: {:ok, Args.normalize_expected(args)}

  defp entry_args(other, index),
    do:
      Options.invalid(@id, "expected[#{index}].args must be a map or :any, got #{inspect(other)}")

  defp count(n, _index) when is_integer(n) and n >= 1, do: {:ok, {n, n}}
  defp count({min, max}, index), do: count_range(min, max, index)
  defp count([min, max], index), do: count_range(min, max, index)

  defp count(%{} = map, index) do
    if Map.keys(map) -- ["min", "max"] == [] and is_map_key(map, "max"),
      do: count_range(Map.get(map, "min", 0), Map.fetch!(map, "max"), index),
      else: count_error(map, index)
  end

  defp count(other, index), do: count_error(other, index)

  defp count_range(min, max, _index)
       when is_integer(min) and is_integer(max) and min >= 0 and max >= 1 and max >= min,
       do: {:ok, {min, max}}

  defp count_range(min, max, index), do: count_error({min, max}, index)

  defp count_error(value, index),
    do:
      Options.invalid(
        @id,
        "expected[#{index}].count must be n >= 1 or {min, max} with max >= 1, got #{inspect(value)}"
      )

  @impl true
  def score(%ScoreInput{trace: %Trace{} = trace}, config) do
    all = Trace.tool_calls(trace, scope: config.scope, include: :all)

    calls =
      if config.include == :all, do: all, else: Enum.filter(all, &(&1.outcome in config.include))

    forbidden = Enum.filter(all, &(&1.name in config.forbid))

    matcher_config = %{
      mode: config.mode,
      parallel: config.parallel,
      arg_config: Args.config(config)
    }

    case Matcher.run(calls, config.expected, matcher_config) do
      {:ok, result} ->
        verdict(trace, result, forbidden, config)

      {:error, :too_large} ->
        Options.scorer_error(@id, :invalid_config, "trajectory too large to match in order")
    end
  end

  def score(%ScoreInput{}, _config), do: Options.missing_trace(@id, "no trace")

  defp verdict(trace, result, forbidden, config) do
    passed? = result.passed? and forbidden == []

    needs_absence? =
      not passed? or forbidden != [] or config.forbid != [] or
        config.mode in [:strict, :unordered, :subset]

    if trace.truncated? and needs_absence? do
      Options.missing_trace(
        @id,
        "trace truncated; the missing tail may hold calls this result depends on"
      )
    else
      details =
        result
        |> Map.take([:matched, :missing, :unexpected, :out_of_order, :arg_mismatches])
        |> Map.merge(%{
          mode: config.mode,
          forbidden:
            Enum.map(forbidden, &%{tool_call_id: &1.id, name: &1.name, outcome: &1.outcome})
        })

      {:ok,
       %Score{
         name: @id,
         value: value(config, result, passed?, forbidden),
         passed?: passed?,
         reason: reason(result, forbidden, config.mode),
         details: details
       }}
    end
  end

  defp value(%{score: :binary}, _result, passed?, _forbidden),
    do: if(passed?, do: :pass, else: :fail)

  defp value(_config, _result, _passed?, [_ | _]), do: 0.0
  defp value(%{mode: :strict}, _result, passed?, []), do: if(passed?, do: 1.0, else: 0.0)
  defp value(%{mode: :superset}, result, _passed?, []), do: result.recall / 1
  defp value(%{mode: :subset}, result, _passed?, []), do: result.precision / 1
  defp value(_config, %{precision: p, recall: r}, _passed?, []) when p + r == 0, do: 0.0
  defp value(_config, %{precision: p, recall: r}, _passed?, []), do: 2 * p * r / (p + r)

  # Counts only: tool names in calls are partly model-chosen text, and the
  # reason is meant to be trusted.
  defp reason(result, forbidden, mode) do
    missing = Enum.sum(Enum.map(result.missing, & &1.count))
    unexpected = length(result.unexpected)

    parts =
      [
        missing > 0 and "#{missing} expected call(s) missing",
        result.out_of_order != [] and
          "#{length(result.out_of_order)} expected call(s) out of order",
        unexpected > 0 and mode in [:strict, :unordered, :subset] and
          "#{unexpected} unexpected call(s)",
        result.arg_mismatches != [] and "#{length(result.arg_mismatches)} argument mismatch(es)",
        forbidden != [] and "#{length(forbidden)} forbidden call(s)"
      ]
      |> Enum.filter(&is_binary/1)

    case parts do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  @impl true
  def describe(config) do
    %{
      mode: config.mode,
      expected: Enum.map(config.expected, &Map.take(&1, [:name, :args, :min, :max])),
      args: describe_mode(config.args),
      args_overrides: Map.new(config.args_overrides, fn {k, v} -> {k, describe_mode(v)} end),
      ignore_args: Enum.map(config.ignore_args, &Regex.source/1),
      arg_defaults: config.arg_defaults,
      numbers: describe_numbers(config.numbers),
      include: config.include,
      scope: describe_scope(config.scope),
      forbid: config.forbid,
      parallel: config.parallel,
      score: config.score
    }
  end

  @doc false
  def describe_mode(fun) when is_function(fun), do: :function
  def describe_mode({:keys, keys}), do: %{keys: keys}
  def describe_mode(mode), do: mode

  @doc false
  def describe_numbers({:tolerance, abs, rel}), do: %{tolerance: %{abs: abs, rel: rel}}
  def describe_numbers(numbers), do: numbers

  @doc false
  def describe_scope({kind, value}), do: %{kind => value}
  def describe_scope(scope), do: scope
end
