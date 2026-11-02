defmodule Nous.Eval.Online.Config do
  @moduledoc false
  # Validates the options of `Nous.Eval.Online` (documented there). Every
  # check fails closed: `{:error, {:invalid_config, reason}}` and the
  # instance does not start.

  alias Nous.Eval.Scorer.Spec
  alias Nous.Eval.Scoring
  alias Nous.Eval.Scoring.Prepared

  @keys [
    :name,
    :instance,
    :sample_rate,
    :redact,
    :store,
    :retention,
    :filter,
    :agents,
    :sample_by,
    :rules,
    :budget,
    :max_in_flight,
    :max_queue,
    :max_concurrency,
    :redact_timeout,
    :score_timeout,
    :max_trace_age,
    :max_events,
    :max_bytes,
    :window_ms,
    :sweep_interval,
    :batch_size,
    :store_retries,
    :store_backoff,
    :prune_interval,
    :exporter
  ]

  @defaults [
    name: Nous.Eval.Online,
    instance: "default",
    filter: nil,
    agents: nil,
    sample_by: :trace,
    rules: [],
    budget: nil,
    max_in_flight: 200,
    max_queue: 1_000,
    max_concurrency: 4,
    redact_timeout: 2_000,
    score_timeout: 30_000,
    max_trace_age: :timer.minutes(15),
    max_events: 2_000,
    max_bytes: 4_000_000,
    window_ms: :timer.minutes(1),
    sweep_interval: :timer.seconds(10),
    batch_size: 100,
    store_retries: 3,
    store_backoff: 1_000,
    prune_interval: :timer.hours(1),
    exporter: nil
  ]

  @pos_int_keys [
    :max_in_flight,
    :max_queue,
    :max_concurrency,
    :redact_timeout,
    :score_timeout,
    :max_trace_age,
    :max_events,
    :max_bytes,
    :window_ms,
    :sweep_interval,
    :batch_size,
    :store_retries,
    :store_backoff,
    :prune_interval
  ]

  @units %{second: 1_000, minute: 60_000, hour: 3_600_000, day: 86_400_000}
  @windows %{minute: 60_000, hour: 3_600_000, day: 86_400_000}
  @default_reserve [input: 16_000, output: 2_000]

  @instance ~r/\A[a-z0-9][a-z0-9_-]{0,47}\z/
  @rule_name ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

  @type rule :: %{
          name: String.t(),
          sample_rate: float(),
          threshold: non_neg_integer(),
          when: (term() -> term()) | nil,
          scorers: [Prepared.t()],
          models: %{optional(String.t()) => %{model: String.t(), calls: pos_integer()}}
        }

  @type t :: %__MODULE__{}

  defstruct @keys ++
              [:threshold, :redactor_version, :retention_ms, :store_module, :store_opts]

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, {:invalid_config, term()}}
  def new(opts) when is_list(opts) do
    with {:ok, opts} <- known_keys(opts),
         {:ok, redact} <- redact(Keyword.get(opts, :redact)),
         {:ok, rate} <- rate(Keyword.get(opts, :sample_rate), :sample_rate),
         {:ok, {store_module, store_opts}} <- store(Keyword.get(opts, :store)),
         {:ok, retention_ms} <- retention(Keyword.fetch(opts, :retention)),
         :ok <- retention_support(store_module, retention_ms),
         opts = Keyword.merge(@defaults, opts),
         :ok <- simple(opts),
         {:ok, rules} <- rules(opts[:rules], rate, redact),
         {:ok, budget} <- budget(opts[:budget], rules) do
      {:ok,
       struct!(
         __MODULE__,
         Keyword.merge(opts,
           redact: redact,
           sample_rate: rate,
           threshold: Nous.Eval.Online.Sampler.threshold(rate),
           redactor_version: redactor_version(redact),
           retention: opts[:retention],
           retention_ms: retention_ms,
           store_module: store_module,
           store_opts: store_opts,
           rules: rules,
           budget: budget,
           agents: opts[:agents] && MapSet.new(opts[:agents])
         )
       )}
    else
      {:error, reason} -> {:error, {:invalid_config, reason}}
    end
  end

  def new(other), do: {:error, {:invalid_config, {:not_a_keyword_list, other}}}

  defp known_keys(opts) do
    case Keyword.validate(opts, @keys) do
      {:ok, opts} -> {:ok, opts}
      {:error, unknown} -> {:error, {:unknown_options, unknown}}
    end
  rescue
    ArgumentError -> {:error, {:not_a_keyword_list, opts}}
  end

  # ── redact ─────────────────────────────────────────────────────────────────

  defp redact(nil), do: {:error, :redact_required}
  defp redact(:drop_content), do: {:ok, :drop_content}
  defp redact(fun) when is_function(fun, 1), do: {:ok, fun}

  defp redact(module) when is_atom(module) and module not in [true, false] do
    if Code.ensure_loaded?(module) and function_exported?(module, :redact, 1),
      do: {:ok, module},
      else: {:error, {:invalid_redact, module}}
  end

  defp redact(other), do: {:error, {:invalid_redact, other}}

  defp redactor_version(module) when is_atom(module) and module != :drop_content do
    if function_exported?(module, :version, 0), do: to_string(module.version())
  end

  defp redactor_version(_redact), do: nil

  # ── rates ──────────────────────────────────────────────────────────────────

  defp rate(value, _key) when is_number(value) and value >= 0 and value <= 1, do: {:ok, value / 1}
  defp rate(nil, :sample_rate), do: {:error, :sample_rate_required}
  defp rate(value, key), do: {:error, {:invalid_rate, key, value}}

  # ── store and retention ────────────────────────────────────────────────────

  defp store(nil), do: {:error, :store_required}
  defp store(module) when is_atom(module), do: store({module, []})

  defp store({module, opts}) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :put_run, 2),
       do: {:ok, {module, opts}},
       else: {:error, {:invalid_store, module}}
  end

  defp store(other), do: {:error, {:invalid_store, other}}

  defp retention(:error), do: {:error, :retention_required}
  defp retention({:ok, :infinity}), do: {:ok, nil}

  defp retention({:ok, opts}) when is_list(opts) do
    case Keyword.validate(opts, [:max_age]) do
      {:ok, [max_age: {n, unit}]} when is_integer(n) and n > 0 and is_map_key(@units, unit) ->
        {:ok, n * Map.fetch!(@units, unit)}

      _ ->
        {:error, {:invalid_retention, opts}}
    end
  end

  defp retention({:ok, other}), do: {:error, {:invalid_retention, other}}

  defp retention_support(_module, nil), do: :ok

  defp retention_support(module, _ms) do
    if function_exported?(module, :delete_runs_before, 3),
      do: :ok,
      else: {:error, {:store_lacks_retention, module}}
  end

  # ── simple options ─────────────────────────────────────────────────────────

  defp simple(opts) do
    cond do
      bad = Enum.find(@pos_int_keys, &(not pos_int?(opts[&1]))) ->
        {:error, {:invalid_option, bad, opts[bad]}}

      not (is_atom(opts[:name]) and opts[:name] not in [nil, true, false]) ->
        {:error, {:invalid_option, :name, opts[:name]}}

      not (is_binary(opts[:instance]) and opts[:instance] =~ @instance) ->
        {:error, {:invalid_option, :instance, opts[:instance]}}

      opts[:sample_by] not in [:trace, :session] ->
        {:error, {:invalid_option, :sample_by, opts[:sample_by]}}

      not optional_fun?(opts[:filter]) ->
        {:error, {:invalid_option, :filter, opts[:filter]}}

      not optional_fun?(opts[:exporter]) ->
        {:error, {:invalid_option, :exporter, opts[:exporter]}}

      not agents?(opts[:agents]) ->
        {:error, {:invalid_option, :agents, opts[:agents]}}

      true ->
        :ok
    end
  end

  defp pos_int?(value), do: is_integer(value) and value > 0
  defp optional_fun?(value), do: is_nil(value) or is_function(value, 1)
  defp agents?(nil), do: true
  defp agents?(list), do: is_list(list) and list != [] and Enum.all?(list, &is_binary/1)

  # ── rules ──────────────────────────────────────────────────────────────────

  defp rules(rules, rate, redact) when is_list(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case rule(rule, rate, redact) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rules} -> unique_names(Enum.reverse(rules))
      error -> error
    end
  end

  defp rules(other, _rate, _redact), do: {:error, {:invalid_option, :rules, other}}

  defp unique_names(rules) do
    names = Enum.map(rules, & &1.name)

    if length(Enum.uniq(names)) == length(names),
      do: {:ok, rules},
      else: {:error, {:duplicate_rule_names, names -- Enum.uniq(names)}}
  end

  defp rule(opts, global_rate, redact) when is_list(opts) do
    with {:ok, opts} <- rule_keys(opts),
         {:ok, name} <- rule_name(opts[:name]),
         {:ok, rate} <- rule_rate(Keyword.get(opts, :sample_rate, global_rate), name),
         :ok <- nested(rate, global_rate, name),
         :ok <- when_fun(opts[:when], name),
         {:ok, specs} <- specs(opts[:scorers], name),
         {:ok, prepared} <- prepare(specs, name),
         :ok <- content_allowed(prepared, redact, name),
         {:ok, models} <- models(prepared, name) do
      {:ok,
       %{
         name: name,
         sample_rate: rate,
         threshold: Nous.Eval.Online.Sampler.threshold(rate),
         when: opts[:when],
         scorers: prepared,
         models: models
       }}
    end
  end

  defp rule(other, _rate, _redact), do: {:error, {:invalid_rule, other}}

  defp rule_keys(opts) do
    case Keyword.validate(opts, [:name, :sample_rate, :when, :scorers]) do
      {:ok, opts} -> {:ok, opts}
      {:error, unknown} -> {:error, {:unknown_rule_options, unknown}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_rule, opts}}
  end

  defp rule_name(name) when is_binary(name) do
    if name =~ @rule_name, do: {:ok, name}, else: {:error, {:invalid_rule_name, name}}
  end

  defp rule_name(name), do: {:error, {:invalid_rule_name, name}}

  defp rule_rate(rate, name) do
    case rate(rate, {:rule, name}) do
      {:ok, rate} -> {:ok, rate}
      {:error, _} -> {:error, {:invalid_rate, {:rule, name}, rate}}
    end
  end

  # Rules sample within captured traces, so a rule rate above the capture
  # rate would claim coverage the capture never provides.
  defp nested(rate, global, name) do
    if rate <= global, do: :ok, else: {:error, {:rule_rate_exceeds_sample_rate, name}}
  end

  defp when_fun(nil, _name), do: :ok
  defp when_fun(fun, _name) when is_function(fun, 1), do: :ok
  defp when_fun(other, name), do: {:error, {:invalid_when, name, other}}

  defp specs([_ | _] = scorers, name) do
    Enum.reduce_while(scorers, {:ok, []}, fn scorer, {:ok, acc} ->
      case spec(scorer) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        :error -> {:halt, {:error, {:invalid_scorer, name, scorer}}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp specs(other, name), do: {:error, {:invalid_scorers, name, other}}

  defp spec(%Spec{} = spec), do: {:ok, spec}

  defp spec({module, opts}) when is_atom(module) and is_list(opts) do
    {composition, scorer_opts} = Keyword.split(opts, [:required, :weight, :skippable])
    {:ok, struct!(Spec, [module: module, opts: scorer_opts] ++ composition)}
  rescue
    ArgumentError -> :error
  end

  defp spec(module) when is_atom(module), do: {:ok, %Spec{module: module}}
  defp spec(_other), do: :error

  defp prepare(specs, name) do
    case Scoring.init(specs) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, {module, reason}} -> {:error, {:scorer_init_failed, name, module, reason}}
    end
  end

  # Under `:drop_content` a scorer that reads content would grade empty
  # values and report them as the agent's quality.
  defp content_allowed(prepared, :drop_content, name) do
    case Enum.find(prepared, &(content(&1.spec.module) != :none)) do
      nil -> :ok
      p -> {:error, {:content_scorer_under_drop_content, name, p.id}}
    end
  end

  defp content_allowed(_prepared, _redact, _name), do: :ok

  defp content(module) do
    if function_exported?(module, :content, 0), do: module.content(), else: :required
  end

  # The model each model-graded scorer pays for: its `:judge` or `:model`
  # option, which must have a price.
  defp models(prepared, name) do
    prepared
    |> Enum.filter(&(&1.kind == :model_graded))
    |> Enum.reduce_while({:ok, %{}}, fn %Prepared{id: id, spec: spec}, {:ok, acc} ->
      case model_of(spec.opts) do
        nil ->
          {:halt, {:error, {:unpriced_scorer, name, id}}}

        model ->
          case Nous.Usage.cost(%Nous.Usage{}, model) do
            {:ok, _} -> {:cont, {:ok, Map.put(acc, id, %{model: model, calls: calls(spec.opts)})}}
            {:error, :unknown_model} -> {:halt, {:error, {:unknown_price, model}}}
          end
      end
    end)
  end

  defp model_of(opts) do
    case Keyword.get(opts, :judge) || Keyword.get(opts, :model) do
      model when is_binary(model) -> model
      {model, _opts} when is_binary(model) -> model
      %Nous.Model{provider: provider, model: model} -> "#{provider}:#{model}"
      _ -> nil
    end
  end

  # Worst-case model requests of one scorer call: each judge sample may be
  # retried once for its structured output.
  defp calls(opts) do
    samples = Keyword.get(opts, :samples, 1)
    if(is_integer(samples) and samples > 0, do: samples, else: 1) * 2
  end

  # ── budget ─────────────────────────────────────────────────────────────────

  defp budget(budget, rules) do
    paid? = Enum.any?(rules, &(map_size(&1.models) > 0))

    cond do
      is_nil(budget) and paid? -> {:error, :budget_required}
      is_nil(budget) -> {:ok, nil}
      true -> validate_budget(budget, rules)
    end
  end

  defp validate_budget(budget, rules) when is_list(budget) do
    with {:ok, opts} <- budget_keys(budget),
         {:ok, max_cost} <- max_cost(opts[:max_cost]),
         {:ok, window_ms} <- window(opts[:per]),
         {:ok, {input, output}} <- reserve_tokens(opts[:reserve_tokens]),
         {:ok, reserves} <- reserves(rules, input, output, max_cost) do
      {:ok, %{max_cost: max_cost, window_ms: window_ms, per: opts[:per], reserves: reserves}}
    end
  end

  defp validate_budget(other, _rules), do: {:error, {:invalid_budget, other}}

  defp budget_keys(budget) do
    case Keyword.validate(budget, [:max_cost, :per, reserve_tokens: @default_reserve]) do
      {:ok, opts} -> {:ok, opts}
      {:error, unknown} -> {:error, {:invalid_budget, unknown}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_budget, budget}}
  end

  defp max_cost(cost) when is_number(cost) and cost > 0, do: {:ok, cost / 1}
  defp max_cost(other), do: {:error, {:invalid_budget, {:max_cost, other}}}

  defp window(per) when is_map_key(@windows, per), do: {:ok, Map.fetch!(@windows, per)}
  defp window(ms) when is_integer(ms) and ms > 0, do: {:ok, ms}
  defp window(other), do: {:error, {:invalid_budget, {:per, other}}}

  defp reserve_tokens(opts) when is_list(opts) do
    case {opts[:input], opts[:output]} do
      {i, o} when is_integer(i) and i > 0 and is_integer(o) and o > 0 -> {:ok, {i, o}}
      _ -> {:error, {:invalid_budget, {:reserve_tokens, opts}}}
    end
  end

  defp reserve_tokens(other), do: {:error, {:invalid_budget, {:reserve_tokens, other}}}

  # USD reserved before each model-graded scorer call: its worst-case
  # requests at the reserve token counts. A reservation above the whole
  # budget could never run.
  defp reserves(rules, input, output, max_cost) do
    usage = %Nous.Usage{input_tokens: input, output_tokens: output, total_tokens: input + output}

    entries =
      for rule <- rules, {id, %{model: model, calls: calls}} <- rule.models do
        {:ok, %{total: per_call}} = Nous.Usage.cost(usage, model)
        {{rule.name, id}, model, per_call * calls}
      end

    case Enum.find(entries, fn {_key, _model, usd} -> usd > max_cost end) do
      nil ->
        {:ok, Map.new(entries, fn {key, model, usd} -> {key, %{model: model, usd: usd}} end)}

      {{rule, id}, _model, usd} ->
        {:error, {:reserve_exceeds_budget, rule, id, usd}}
    end
  end
end
