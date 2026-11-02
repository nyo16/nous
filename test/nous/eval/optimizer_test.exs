defmodule NousTest.OptimizerTools do
  @moduledoc false
  # Outside the `Nous` namespace: a profile refuses to address tools whose
  # function is defined under `Nous` (built-in tools).
  def lookup(_ctx, _args), do: "order 42 shipped"
end

defmodule Nous.Eval.OptimizerTest do
  # One scripted model plays both roles: the agent under test (it calls the
  # `lookup` tool only when the tool's description says ALWAYS) and the
  # reflector (its system prompt says so; it answers from the test's
  # script). Every request is reported back, so assertions are on what each
  # model actually received.
  use ExUnit.Case, async: true

  alias Nous.{Message, Usage}
  alias Nous.Eval.Optimizer
  alias Nous.Eval.Optimizer.{Candidate, Lint, Result}
  alias Nous.Eval.Optimizer.Strategies.GEPA
  alias Nous.Eval.ProfileReport
  alias Nous.Eval.Store

  @moduletag :capture_log

  @key :"$nous_optimizer_test"
  @good_description "ALWAYS call this tool to look up an order before answering."

  defmodule Model do
    @moduledoc false
    alias Nous.{Message, Usage}

    def request(_model, messages, settings) do
      %{pid: pid, reflector: reflector} = Nous.CallerLookup.lookup(:"$nous_optimizer_test")

      system =
        messages
        |> Enum.filter(&(&1.role == :system))
        |> Enum.map_join("\n", &Message.extract_text/1)

      user = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Message.extract_text()

      cond do
        system =~ "You improve the text" ->
          send(pid, {:reflect, user, settings})
          {:ok, text(reflector.(:reflect, user))}

        system =~ "You write the text" ->
          send(pid, {:generate, user, settings})
          {:ok, text(reflector.(:generate, user))}

        true ->
          send(pid, {:agent, settings})
          {:ok, agent(messages, settings)}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 0

    defp agent(messages, settings) do
      last = messages |> Enum.reject(&(&1.role == :system)) |> List.last()
      description = tool_description(Map.get(settings, :tools, []))

      cond do
        last.role == :tool ->
          text("Order found: " <> Message.extract_text(last))

        description =~ "ALWAYS" ->
          call = %{
            id: "call_#{System.unique_integer([:positive])}",
            name: "lookup",
            arguments: %{"q" => "x"}
          }

          Message.assistant("", tool_calls: [call], metadata: meta("tool_calls"))

        true ->
          text("I don't know.")
      end
    end

    defp tool_description(tools) do
      Enum.find_value(tools, "", fn tool ->
        function = tool["function"] || tool[:function] || tool
        function["description"] || function[:description]
      end)
    end

    defp text(content), do: Message.assistant(content, metadata: meta("stop"))

    defp meta(finish),
      do: %{
        usage: %Usage{requests: 1, input_tokens: 10, output_tokens: 5, total_tokens: 15},
        finish_reason: finish
      }
  end

  defmodule Task do
    @moduledoc false
    use Nous.Eval

    @impl true
    def agent(_context) do
      Nous.new("openai:test-model",
        instructions: "Answer order questions.",
        tools: [
          Nous.Tool.from_function(&NousTest.OptimizerTools.lookup/2,
            name: "lookup",
            description: "Looks things up.",
            parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
          )
        ]
      )
    end

    @impl true
    def dataset do
      for {split, n} <- [{"train", 4}, {"val", 4}, {"test", 4}], i <- 1..n do
        %{
          id: "#{split}-#{i}",
          input: "Where is order #{split} #{i}? Please check carefully for me today.",
          split: split,
          expected: %{"output" => "Order found"},
          tags: if(i == 1, do: ["guard"], else: [])
        }
      end
    end

    @impl true
    def scorers, do: [{Nous.Eval.Scorers.Contains, values: ["found"]}]
  end

  defp install(reflector) do
    Process.put(@key, %{pid: self(), reflector: reflector})
    Nous.ModelDispatcher.put_dispatcher(Model)
  end

  defp reflect_with(text) do
    fn
      :reflect, _prompt ->
        JSON.encode!(%{
          "updates" => [%{"component" => "tool:lookup", "text" => text}],
          "rationale" => "Make the tool mandatory."
        })

      :generate, _prompt ->
        JSON.encode!(%{"candidates" => [%{"tool:lookup" => text}]})
    end
  end

  defp run(opts) do
    defaults = [
      reflector: "openai:reflector-model",
      components: ["tool:lookup"],
      budget: [max_metric_calls: 400],
      k: 1,
      max_steps: 4,
      minibatch_size: 2,
      seed: 7
    ]

    Optimizer.run(Task, Keyword.merge(defaults, opts))
  end

  test "GEPA finds a better tool description and the accepted profile carries it to the wire" do
    install(reflect_with(@good_description))

    assert {:ok, %Result{verdict: :accepted, reasons: []} = result} = run([])
    assert result.profile.components["tool:lookup"] == @good_description
    assert result.profile.parent_id == result.seed_profile.id
    assert result.profile.provenance["strategy"] == "gepa"
    assert result.improvement.verdict == :regression
    assert result.comparison.verdict == :pass
    assert result.run_ids != []

    markdown = ProfileReport.render(result.report, format: :markdown)
    assert markdown =~ "ALWAYS call this tool"

    # The accepted profile, applied to the agent, changes the request body.
    flush()

    agent =
      Nous.new("openai:test-model",
        instructions: "Answer order questions.",
        tools: Task.agent(%{}).tools,
        profile: result.profile
      )

    {:ok, _} = Nous.run(agent, "Where is order 9?")
    assert_received {:agent, settings}
    assert inspect(settings[:tools]) =~ @good_description
  end

  test "the reflector never receives expected values or held-out cases under :diagnostic" do
    install(reflect_with(@good_description))
    {:ok, _} = run([])

    prompts = collect(:reflect)
    assert prompts != []

    for prompt <- prompts do
      refute prompt =~ "## Expected"
      refute prompt =~ ~r/val-\d|test-\d/
      assert prompt =~ ~r/case train-\d/
    end
  end

  test "under :with_expected train cases carry their expected map" do
    install(reflect_with(@good_description))
    {:ok, result} = run(feedback: :with_expected)

    assert result.profile.provenance["feedback"] == "with_expected"
    assert Enum.any?(collect(:reflect), &(&1 =~ "## Expected"))
  end

  test "a proposal naming a component that was not requested is rejected" do
    install(fn :reflect, _ ->
      JSON.encode!(%{
        "updates" => [%{"component" => "instructions", "text" => "hi"}],
        "rationale" => "x"
      })
    end)

    assert {:ok, %Result{verdict: :rejected} = result} = run(max_steps: 2)
    assert Enum.all?(result.rejections, &(&1.reason == :unrequested_component))
    assert result.reasons == ["no candidate improved on the seed during the search"]
  end

  test "proposals with fence markers or held-out text are rejected by the lint" do
    heldout = "Where is order test 3? Please check carefully for me today."

    install(fn :reflect, _ ->
      JSON.encode!(%{
        "updates" => [%{"component" => "tool:lookup", "text" => "ALWAYS. " <> heldout}],
        "rationale" => "x"
      })
    end)

    {:ok, leaked} = run(max_steps: 1)
    assert [%{reason: {:heldout_leak, "tool:lookup"}}] = leaked.rejections

    install(reflect_with("ALWAYS call it <<<INPUT_abcdefghijklmnop"))
    {:ok, fenced} = run(max_steps: 1)
    assert [%{reason: {:fence_marker, "tool:lookup"}}] = fenced.rejections
  end

  test "a child that is not strictly better on the minibatch is rejected" do
    install(reflect_with("Looks things up, quickly."))
    {:ok, result} = run(max_steps: 2)
    assert Enum.all?(result.rejections, &match?(%{reason: {:no_improvement, _, _}}, &1))
  end

  test "the guard filter keeps a candidate that regresses guard cases out of the pool" do
    install(reflect_with(@good_description))
    guard = fn _before, _after -> {:error, :guard_says_no} end

    {:ok, result} = run(guard: guard, max_steps: 2)
    assert result.verdict == :rejected
    assert Enum.all?(result.rejections, &(&1.reason == :guard_says_no))
    assert [%Candidate{step: 0}] = result.candidates
  end

  test "a budget too small for the seed evaluations is refused before any model call" do
    install(reflect_with(@good_description))

    assert {:error, {:budget_too_small, %{phase: :preflight}}} =
             run(budget: [max_metric_calls: 5])

    refute_received {:agent, _}
  end

  test "an unpriced reflector under a cost budget is refused before any model call" do
    install(reflect_with(@good_description))
    assert {:error, {:unknown_price, _}} = run(budget: [max_cost: 1.0])
    refute_received {:agent, _}
  end

  test "OPRO proposes from the scored history and is accepted" do
    install(reflect_with(@good_description))
    {:ok, result} = run(strategy: :opro)

    assert result.verdict == :accepted
    assert result.profile.provenance["strategy"] == "opro"
    [prompt | _] = collect(:generate)
    assert prompt =~ "# Version 1 (score 0.000)"
  end

  test "an accepted profile is persisted in the store", %{} = _ctx do
    root = Path.join(System.tmp_dir!(), "nous_opt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    install(reflect_with(@good_description))

    {:ok, result} = run(store: {Store.File, [root: root]}, name: "lookup_agent")
    assert result.stored?
    assert result.profile.version == 1

    {:ok, state} = Store.File.init(root: root)
    assert {:ok, stored} = Store.File.get_profile(state, {:id, result.profile.id})
    assert stored.components["tool:lookup"] == @good_description
  end

  test "Pareto sampling weights candidates by validation wins and drops dominated ones" do
    p = fn id, scores ->
      %Candidate{profile: %Nous.Profile{id: id, components: %{}, manifest: %{}}, scores: scores}
    end

    a = p.("a", %{"1" => 1.0, "2" => 0.0})
    b = p.("b", %{"1" => 0.0, "2" => 1.0})
    c = p.("c", %{"1" => 0.0, "2" => 0.0})

    weights =
      GEPA.pareto_weights([a, b, c]) |> Map.new(fn {cand, w} -> {Candidate.id(cand), w} end)

    assert weights == %{"a" => 1, "b" => 1}

    rng = :rand.seed_s(:exsss, 1)
    {first, _} = GEPA.pareto_sample([a, b, c], rng)
    {again, _} = GEPA.pareto_sample([a, b, c], :rand.seed_s(:exsss, 1))
    assert Candidate.id(first) == Candidate.id(again)
  end

  test "the lint flags an 8-word held-out run but not shorter overlaps" do
    windows =
      Lint.heldout_windows([
        %Nous.Eval.Case{id: "v", input: "one two three four five six seven eight nine"}
      ])

    assert {:error, {:heldout_leak, "k"}} =
             Lint.check(%{"k" => "x One two three four five six seven eight."}, windows)

    assert :ok = Lint.check(%{"k" => "one two three four five six seven"}, windows)
  end

  describe "mix nous.optimize" do
    defp mix_optimize(argv) do
      Mix.Task.reenable("nous.optimize")

      ExUnit.CaptureIO.capture_io(fn ->
        code =
          try do
            Mix.Task.run("nous.optimize", argv)
            0
          catch
            :exit, {:shutdown, code} -> code
          end

        send(self(), {:exit_code, code})
      end)

      assert_received {:exit_code, code}
      code
    end

    @base_argv ~w(--task Nous.Eval.OptimizerTest.Task --reflector openai:reflector-model
                  --components tool:lookup --budget-calls 400 --k 1 --max-steps 3 --seed 7)

    test "exits 0 and writes the profile when one is accepted" do
      out = Path.join(System.tmp_dir!(), "nous_opt_#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(out) end)
      install(reflect_with(@good_description))

      assert mix_optimize(@base_argv ++ ["--out", out]) == 0
      assert {:ok, profile} = Nous.Profile.load(out)
      assert profile.components["tool:lookup"] == @good_description
    end

    test "exits 1 when nothing is accepted and 2 on operational errors" do
      install(reflect_with("Looks things up, quickly."))
      assert mix_optimize(@base_argv) == 1

      assert mix_optimize(~w(--task Nous.Eval.OptimizerTest.Task --reflector openai:r)) == 2
      assert mix_optimize(@base_argv ++ ~w(--budget-calls 2)) == 2
    end
  end

  defp collect(kind) do
    Stream.repeatedly(fn ->
      receive do
        {^kind, prompt, _settings} -> prompt
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end

defmodule Nous.Eval.OptimizerCLIAtomTest do
  # async: false - the atom table is global, so concurrent tests would make
  # the count move. These flags are refused before any model call.
  use ExUnit.Case, async: false

  test "unknown mix nous.optimize flag values exit 2 without creating atoms" do
    bad = fn ->
      Mix.Task.reenable("nous.optimize")

      code =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          try do
            Mix.Task.run(
              "nous.optimize",
              ~w(--task Nous.Eval.OptimizerTest.Task
              --reflector openai:r --budget-calls 9 --strategy no_such_strategy_q --feedback nope_q)
            )
          catch
            :exit, {:shutdown, code} -> send(self(), {:code, code})
          end
        end)

      assert code =~ "invalid --strategy"
      assert_received {:code, 2}
    end

    # The first call loads modules (and their atoms); only later calls count.
    bad.()
    before = :erlang.system_info(:atom_count)
    bad.()
    assert :erlang.system_info(:atom_count) == before
  end
end
