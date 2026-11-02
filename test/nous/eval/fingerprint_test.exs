defmodule Nous.Eval.FingerprintTest do
  # async: false - two tests assert on what was (not) logged, and
  # capture_log also sees warnings from concurrently running modules (any
  # eval run whose agent has anonymous instructions logs the same warning).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.Eval.{CanonicalJSON, Dataset, Fingerprint}
  alias Nous.Eval.Scorer.Spec

  defmodule JudgeLike do
    @behaviour Nous.Eval.Scorer

    @impl true
    def id, do: "judge_like"

    @impl true
    def init(opts) do
      if Keyword.has_key?(opts, :rubric),
        do: {:ok, Map.new(opts)},
        else: {:error, :invalid_config}
    end

    @impl true
    def score(_input, _config), do: {:skip, "test"}

    @impl true
    def describe(config) do
      %{model: "openai:gpt-4o", prompt_hash: CanonicalJSON.digest(config.rubric), scale: {1, 5}}
    end
  end

  defmodule Plain do
    @behaviour Nous.Eval.Scorer

    @impl true
    def id, do: "plain"
    @impl true
    def init(opts), do: {:ok, opts}
    @impl true
    def score(_input, _config), do: {:skip, "test"}
  end

  defmodule Instructions do
    def text(_ctx), do: "Named instructions."
    def search(_ctx, _args), do: "ok"
  end

  defp tool(description) do
    %Nous.Tool{
      name: "search_orders",
      description: description,
      parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}},
      function: &Instructions.search/2
    }
  end

  defp agent(opts \\ []) do
    Nous.new(
      Keyword.get(opts, :model, "openai:gpt-4o-mini"),
      api_key: "sk-secret-key",
      instructions: Keyword.get(opts, :instructions, "You are Acme's support agent."),
      tools: [tool(Keyword.get(opts, :tool_description, "Find orders."))],
      model_settings: %{temperature: 0.0}
    )
  end

  defp dataset do
    {:ok, dataset} = Dataset.new([%{id: "a", input: "x"}])
    dataset
  end

  defp scorers(rubric \\ "Be accurate.") do
    [
      %Spec{module: JudgeLike, opts: [rubric: rubric], required: false, weight: 2},
      %Spec{module: Plain}
    ]
  end

  defp build!(agent, scorers, opts \\ []) do
    {:ok, fingerprint} =
      Fingerprint.build(
        __MODULE__,
        agent,
        dataset(),
        scorers,
        Keyword.merge([k: 3, seed: 42], opts)
      )

    fingerprint
  end

  test "is stable for the same configuration, and stores as plain JSON" do
    a = build!(agent(), scorers())
    b = build!(agent(), scorers())

    assert a["id"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert a == b
    assert JSON.decode!(JSON.encode!(a)) == a
    assert a["id"] == a |> Map.delete("id") |> CanonicalJSON.hash()
  end

  test "records every component" do
    fp = build!(agent(), scorers(), deps: %{loop_guard_config: %{thresholds: [4, 8]}})

    assert fp["model"] == "openai:gpt-4o-mini"
    assert fp["model_settings"] == %{"temperature" => 0.0}

    assert fp["instructions"] == %{
             "hash" => CanonicalJSON.digest("You are Acme's support agent.")
           }

    assert fp["tools"]["names"] == ["search_orders"]

    assert fp["guards"] == %{
             "plugins" => [],
             "config" => %{"loop_guard_config" => %{"thresholds" => [4, 8]}}
           }

    assert fp["profile_id"] == nil
    assert fp["dataset"] == dataset().hash
    assert {fp["k"], fp["seed"], fp["seed_forwarded"]} == {3, 42, true}
    assert fp["nous_version"] == Application.spec(:nous, :vsn) |> to_string()
    assert fp["schema_version"] == Nous.Eval.Run.schema_version()
    assert fp["task"] == "Elixir.Nous.Eval.FingerprintTest"

    assert [judge, plain] = fp["scorers"]
    assert judge["prompt_hash"] == CanonicalJSON.digest("Be accurate.")
    assert judge["describe"]["scale"] == %{"tuple" => [1, 5]}
    assert judge["opts"] == %{"rubric" => "Be accurate."}
    assert {judge["required"], judge["weight"]} == {false, 2}
    assert plain["describe"] == nil
  end

  test "changes when instructions, a tool description, a scorer option or k change" do
    base = build!(agent(), scorers())["id"]

    for {label, fp} <- [
          instructions: build!(agent(instructions: "You are terse."), scorers()),
          tool: build!(agent(tool_description: "Find orders by email."), scorers()),
          scorer_option: build!(agent(), scorers("Be kind.")),
          k: build!(agent(), scorers(), k: 5),
          model: build!(agent(model: "openai:gpt-4o"), scorers()),
          guard: build!(agent(), scorers(), deps: %{input_guard_config: %{policy: :block}})
        ] do
      refute fp["id"] == base, "#{label} did not change the fingerprint"
    end
  end

  test "ignores model credentials and unrelated deps" do
    guard_model = Nous.Model.parse("openai:gpt-4o", api_key: "sk-guard")

    fp =
      build!(agent(), scorers(),
        deps: %{api_token: "unrelated-dep-token", decision_guard_config: %{model: guard_model}}
      )

    encoded = CanonicalJSON.encode(fp)

    refute encoded =~ "sk-secret-key"
    refute encoded =~ "sk-guard"
    refute encoded =~ "unrelated-dep-token"
    assert fp["guards"]["config"]["decision_guard_config"]["model"]["model"] == "openai:gpt-4o"
  end

  test "named function instructions are identified by module, name and arity" do
    log =
      capture_log(fn ->
        fp = build!(agent(instructions: &Instructions.text/1), scorers())

        assert fp["instructions"] == %{
                 "function" => %{
                   "module" => "Elixir.Nous.Eval.FingerprintTest.Instructions",
                   "name" => "text",
                   "arity" => 1
                 },
                 "hash" => CanonicalJSON.digest("Named instructions.")
               }
      end)

    refute log =~ "anonymous function"
  end

  test "anonymous functions are fingerprinted as anonymous, with a warning" do
    log =
      capture_log(fn ->
        fp = build!(agent(instructions: fn _ctx -> "Inline." end), scorers())

        assert fp["instructions"] == %{
                 "function" => "anonymous",
                 "hash" => CanonicalJSON.digest("Inline.")
               }
      end)

    assert log =~ "agent instructions: an anonymous function"
    assert log =~ "cannot be fingerprinted"

    log =
      capture_log(fn ->
        fp =
          build!(agent(), scorers(),
            deps: %{decision_guard_config: %{on_verdict: fn _ -> :ok end}}
          )

        assert fp["guards"]["config"]["decision_guard_config"]["on_verdict"] == %{
                 "function" => "anonymous"
               }
      end)

    assert log =~ "deps :decision_guard_config: an anonymous function"
  end

  test "instructions that need deps still fingerprint, without a text hash" do
    capture_log(fn ->
      fp = build!(agent(instructions: fn ctx -> "Hi " <> ctx.deps.name end), scorers())
      assert fp["instructions"] == %{"function" => "anonymous", "hash" => nil}
    end)
  end

  test "seed_forwarded follows the provider's seed_param and needs a seed" do
    assert Nous.Providers.Anthropic.seed_param() == nil
    assert Nous.Providers.Mistral.seed_param() == "random_seed"
    assert Nous.Providers.Gemini.seed_param() == "seed"

    refute build!(agent(model: "anthropic:claude-sonnet-4-5"), scorers())["seed_forwarded"]
    assert build!(agent(model: "gemini:gemini-2.0-flash"), scorers())["seed_forwarded"]
    assert build!(agent(model: "groq:llama-3.3-70b"), scorers())["seed_forwarded"]
    refute build!(agent(), scorers(), seed: nil)["seed_forwarded"]
  end

  test "a scorer whose init/1 rejects its options is an error" do
    assert {:error, {:scorer_init_failed, JudgeLike, :invalid_config}} =
             Fingerprint.build(__MODULE__, agent(), dataset(), [
               %Spec{module: JudgeLike, opts: []}
             ])
  end
end
