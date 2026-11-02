defmodule Nous.Eval.Simulator.Cases do
  @moduledoc false
  # Parses the simulation keys of a `nous.sim_case/1` case (research
  # simulator.md §4.2) into a `Nous.Eval.Simulator.Scenario`, the normalized
  # `expected` map and the scorer specs that judge the episode.
  #
  # The keys every case shares (`id`, `split`, `group`, `tags`, `threshold`,
  # `metadata`, `scorers`) are checked by `Nous.Eval.Dataset`, so a simulated
  # case follows exactly the rules of any other case. Here every key is a
  # string and every enum goes through a literal table: nothing in a case
  # becomes an atom.
  #
  # The scorers follow τ²-bench's `reward_basis`: each listed component
  # (`state`, `said`, `tools`) is a required scorer, so the sample passes only
  # when every one of them does (a product reward); a component given but not
  # listed is tracked with `required: false, weight: 0`. An adversarial case is
  # judged by the breach scorer alone.

  alias Nous.Eval.Scorer.Spec
  alias Nous.Eval.Simulator.Scenario
  alias Nous.Eval.Simulator.Scorers.{Breach, Rubric, Said, State, Tools}

  @keys ["kind", "fixture", "max_turns", "user", "attack", "expected"]

  @kinds %{"task" => :task, "adversarial" => :adversarial}

  @strategies %{
    "direct" => :direct,
    "crescendo" => :crescendo,
    "roleplay" => :roleplay,
    "persuasion" => :persuasion
  }

  @max_turns 50

  @user_keys ["persona", "goal", "known", "unknown", "constraints", "opener", "done_when"]

  @components ["state", "said", "tools"]
  @component_scorers %{"state" => State, "said" => Said, "tools" => Tools}
  @terminations ["stop", "transfer", "out_of_scope"]

  @doc false
  # The case keys this module owns.
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc false
  @spec parse(map()) :: {:ok, Scenario.t(), map(), [Spec.t()]} | {:error, String.t()}
  def parse(fields) when is_map(fields) do
    with {:ok, kind} <- kind(Map.get(fields, "kind", "task")),
         {:ok, max_turns} <- max_turns(Map.fetch(fields, "max_turns")),
         {:ok, fixture} <- optional_text(Map.get(fields, "fixture"), "fixture"),
         {:ok, user} <- user(Map.get(fields, "user"), kind),
         {:ok, attack} <- attack(Map.get(fields, "attack"), kind),
         {:ok, expected, specs} <- expected(Map.get(fields, "expected"), kind) do
      scenario =
        struct!(
          Scenario,
          [kind: kind, max_turns: max_turns, fixture: fixture, attack: attack] ++ user
        )

      {:ok, scenario, expected, specs}
    end
  end

  defp kind(value) do
    case Map.fetch(@kinds, value) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, "kind must be task or adversarial, got #{inspect(value)}"}
    end
  end

  defp max_turns({:ok, n}) when is_integer(n) and n >= 1 and n <= @max_turns, do: {:ok, n}

  defp max_turns(:error),
    do: {:error, "max_turns is required (the most messages the user may send, 1..#{@max_turns})"}

  defp max_turns({:ok, other}),
    do: {:error, "max_turns must be an integer in 1..#{@max_turns}, got #{inspect(other)}"}

  # ── user ──────────────────────────────────────────────────────────────────

  defp user(nil, :adversarial), do: {:ok, []}
  defp user(nil, :task), do: {:error, "user is required (at least a goal)"}

  defp user(%{} = user, kind) do
    with :ok <- known_keys(user, @user_keys, "user"),
         {:ok, persona} <- optional_text(user["persona"], "user.persona"),
         {:ok, goal} <- goal(user["goal"], kind),
         {:ok, known} <- known(Map.get(user, "known", %{})),
         {:ok, unknown} <- text_list(Map.get(user, "unknown", []), "user.unknown"),
         {:ok, constraints} <- text_list(Map.get(user, "constraints", []), "user.constraints"),
         {:ok, opener} <- optional_text(user["opener"], "user.opener"),
         {:ok, done_when} <- optional_text(user["done_when"], "user.done_when") do
      {:ok,
       [
         persona: persona,
         goal: goal,
         known: known,
         unknown: unknown,
         constraints: constraints,
         opener: opener,
         done_when: done_when
       ]}
    end
  end

  defp user(other, _kind), do: {:error, "user must be a mapping, got #{inspect(other)}"}

  defp goal(nil, :task), do: {:error, "user.goal is required"}
  defp goal(value, _kind), do: optional_text(value, "user.goal")

  defp known(%{} = facts) do
    Enum.reduce_while(facts, {:ok, %{}}, fn
      {name, value}, {:ok, acc}
      when is_binary(name) and name != "" and
             (is_binary(value) or is_number(value) or is_boolean(value)) ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      {name, value}, _acc ->
        {:halt,
         {:error,
          "user.known: #{inspect(name)} must map to a string, number or boolean, got " <>
            inspect(value)}}
    end)
  end

  defp known(other), do: {:error, "user.known must be a mapping, got #{inspect(other)}"}

  # ── attack ────────────────────────────────────────────────────────────────

  defp attack(nil, :task), do: {:ok, nil}
  defp attack(_attack, :task), do: {:error, "attack is only allowed on kind: adversarial"}
  defp attack(nil, :adversarial), do: {:error, "attack is required on kind: adversarial"}

  defp attack(%{} = attack, :adversarial) do
    with :ok <- known_keys(attack, ["objective", "strategy"], "attack"),
         {:ok, objective} <- required_text(attack["objective"], "attack.objective"),
         {:ok, strategy} <- strategy(Map.get(attack, "strategy", "direct")) do
      {:ok, %{objective: objective, strategy: strategy}}
    end
  end

  defp attack(other, _kind), do: {:error, "attack must be a mapping, got #{inspect(other)}"}

  defp strategy(value) do
    case Map.fetch(@strategies, value) do
      {:ok, strategy} ->
        {:ok, strategy}

      :error ->
        {:error,
         "attack.strategy must be one of #{Enum.join(Map.keys(@strategies), ", ")}, got " <>
           inspect(value)}
    end
  end

  # ── expected ──────────────────────────────────────────────────────────────

  defp expected(nil, :task),
    do: {:error, "expected is required (at least one of state, said, tools)"}

  defp expected(nil, :adversarial), do: {:error, "expected.breach_when is required"}

  defp expected(%{} = expected, :task) do
    with :ok <-
           known_keys(
             expected,
             ["reward_basis", "state", "said", "tools", "terminations", "rubric"],
             "expected"
           ),
         {:ok, state} <- optional(expected, "state", &state_list(&1, "expected.state")),
         {:ok, said} <- optional(expected, "said", &non_empty_text_list(&1, "expected.said")),
         {:ok, tools} <- optional(expected, "tools", &tools/1),
         {:ok, terminations} <- terminations(Map.get(expected, "terminations", @terminations)),
         {:ok, rubric} <- optional(expected, "rubric", &rubric/1),
         components = given_components(state, said, tools),
         {:ok, basis} <- reward_basis(Map.fetch(expected, "reward_basis"), components) do
      normalized =
        %{"reward_basis" => basis, "terminations" => terminations}
        |> put_given("state", state)
        |> put_given("said", said)
        |> put_given("tools", tools)
        |> put_given("rubric", rubric)

      {:ok, normalized, component_specs(components, basis) ++ rubric_specs(rubric)}
    end
  end

  defp expected(%{} = expected, :adversarial) do
    with :ok <- known_keys(expected, ["breach_when"], "expected"),
         {:ok, breach} <- breach_when(Map.get(expected, "breach_when")) do
      {:ok, %{"breach_when" => breach}, [%Spec{module: Breach}]}
    end
  end

  defp expected(other, _kind), do: {:error, "expected must be a mapping, got #{inspect(other)}"}

  defp optional(map, key, parser) do
    case Map.fetch(map, key) do
      {:ok, value} -> parser.(value)
      :error -> {:ok, nil}
    end
  end

  defp given_components(state, said, tools) do
    for {name, value} <- [{"state", state}, {"said", said}, {"tools", tools}],
        value != nil,
        do: name
  end

  defp put_given(map, _key, nil), do: map
  defp put_given(map, key, value), do: Map.put(map, key, value)

  defp reward_basis(:error, []),
    do: {:error, "expected must give at least one of state, said, tools"}

  defp reward_basis(:error, components), do: {:ok, components}

  defp reward_basis({:ok, [_ | _] = basis}, components) do
    cond do
      not Enum.all?(basis, &(&1 in @components)) ->
        {:error,
         "expected.reward_basis: components are #{Enum.join(@components, ", ")}, got " <>
           inspect(basis)}

      (missing = Enum.reject(basis, &(&1 in components))) != [] ->
        {:error,
         "expected.reward_basis names #{Enum.join(missing, ", ")}, which expected does not give"}

      true ->
        # Canonical order, so the same basis always hashes the same.
        {:ok, Enum.filter(@components, &(&1 in basis))}
    end
  end

  defp reward_basis({:ok, other}, _components),
    do: {:error, "expected.reward_basis must be a non-empty list, got #{inspect(other)}"}

  defp component_specs(components, basis) do
    Enum.map(components, fn component ->
      if component in basis,
        do: %Spec{module: Map.fetch!(@component_scorers, component)},
        else: %Spec{module: Map.fetch!(@component_scorers, component), required: false, weight: 0}
    end)
  end

  defp rubric_specs(nil), do: []

  # The judge is told whether it gates (its `required`), as the runner tells
  # a task-level judge.
  defp rubric_specs(%{"judge" => judge, "criteria" => criteria, "gate" => gate}) do
    [
      %Spec{
        module: Rubric,
        opts: [judge: judge, rubric: criteria, gate: gate],
        required: gate,
        weight: if(gate, do: 1, else: 0)
      }
    ]
  end

  defp state_list([_ | _] = entries, where) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case state_entry(entry) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, message} -> {:halt, {:error, "#{where} #{index}: #{message}"}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp state_list(other, where),
    do: {:error, "#{where} must be a non-empty list of {path, equals}, got #{inspect(other)}"}

  defp state_entry(%{"path" => [_ | _] = path, "equals" => value} = entry)
       when map_size(entry) == 2 do
    if Enum.all?(path, &((is_binary(&1) and &1 != "") or (is_integer(&1) and &1 >= 0))),
      do: {:ok, %{"path" => path, "equals" => value}},
      else: {:error, "path segments are non-empty strings or list indexes, got #{inspect(path)}"}
  end

  defp state_entry(other),
    do: {:error, "expected a {path: [..], equals: value} mapping, got #{inspect(other)}"}

  defp tools(%{} = tools) do
    with :ok <- known_keys(tools, ["forbidden", "required"], "expected.tools"),
         {:ok, forbidden} <-
           text_list(Map.get(tools, "forbidden", []), "expected.tools.forbidden"),
         {:ok, required} <- text_list(Map.get(tools, "required", []), "expected.tools.required") do
      if forbidden == [] and required == [],
        do: {:error, "expected.tools must list forbidden or required tools"},
        else: {:ok, %{"forbidden" => forbidden, "required" => required}}
    end
  end

  defp tools(other), do: {:error, "expected.tools must be a mapping, got #{inspect(other)}"}

  defp terminations([_ | _] = list) do
    if Enum.all?(list, &(&1 in @terminations)),
      do: {:ok, Enum.filter(@terminations, &(&1 in list))},
      else:
        {:error,
         "expected.terminations: allowed are #{Enum.join(@terminations, ", ")}, got " <>
           inspect(list)}
  end

  defp terminations(other),
    do: {:error, "expected.terminations must be a non-empty list, got #{inspect(other)}"}

  defp rubric(%{} = rubric) do
    with :ok <- known_keys(rubric, ["judge", "criteria", "gate"], "expected.rubric"),
         {:ok, judge} <- required_text(rubric["judge"], "expected.rubric.judge"),
         {:ok, criteria} <- required_text(rubric["criteria"], "expected.rubric.criteria"),
         {:ok, gate} <- boolean(Map.get(rubric, "gate", false), "expected.rubric.gate") do
      {:ok, %{"judge" => judge, "criteria" => criteria, "gate" => gate}}
    end
  end

  defp rubric(other),
    do: {:error, "expected.rubric must be a {judge, criteria} mapping, got #{inspect(other)}"}

  defp breach_when(%{} = breach) do
    where = "expected.breach_when"

    with :ok <- known_keys(breach, ["state", "tools", "leaked"], where),
         {:ok, state} <- optional(breach, "state", &state_list(&1, where <> ".state")),
         {:ok, tools} <- optional(breach, "tools", &non_empty_text_list(&1, where <> ".tools")),
         {:ok, leaked} <-
           optional(breach, "leaked", &non_empty_text_list(&1, where <> ".leaked")) do
      if state == nil and tools == nil and leaked == nil do
        {:error, "#{where} must give at least one of state, tools, leaked"}
      else
        {:ok,
         %{}
         |> put_given("state", state)
         |> put_given("tools", tools)
         |> put_given("leaked", leaked)}
      end
    end
  end

  defp breach_when(nil),
    do: {:error, "expected.breach_when is required on kind: adversarial"}

  defp breach_when(other),
    do: {:error, "expected.breach_when must be a mapping, got #{inspect(other)}"}

  # ── shared checks ─────────────────────────────────────────────────────────

  defp known_keys(map, allowed, where) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, "#{where}: unknown key #{inspect(key)}"}
    end
  end

  defp required_text(value, _where) when is_binary(value) and value != "", do: {:ok, value}

  defp required_text(value, where),
    do: {:error, "#{where} must be a non-empty string, got #{inspect(value)}"}

  defp optional_text(nil, _where), do: {:ok, nil}
  defp optional_text(value, where), do: required_text(value, where)

  defp text_list(list, where) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: {:error, "#{where} must be a list of non-empty strings, got #{inspect(list)}"}
  end

  defp text_list(other, where),
    do: {:error, "#{where} must be a list of non-empty strings, got #{inspect(other)}"}

  defp non_empty_text_list([_ | _] = list, where), do: text_list(list, where)

  defp non_empty_text_list(other, where),
    do: {:error, "#{where} must be a non-empty list of strings, got #{inspect(other)}"}

  defp boolean(value, _where) when is_boolean(value), do: {:ok, value}
  defp boolean(value, where), do: {:error, "#{where} must be a boolean, got #{inspect(value)}"}
end
