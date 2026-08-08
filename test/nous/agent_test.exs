defmodule Nous.AgentTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Message, Model, ModelDispatcher, Tool, Usage}

  defmodule EchoDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      send(self(), {:dispatched_messages, messages})

      {:ok,
       Message.from_legacy(%{
         parts: [{:text, "ok"}],
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end

  defmodule SamplePlugin do
    @moduledoc false
    def system_prompt(_agent, _ctx), do: nil
  end

  # Public so `&__MODULE__.sample_tool_fn/2` can be captured the way callers do.
  def sample_tool_fn(_ctx, _args), do: %{ok: true}

  describe "new/2 defaults" do
    test "parses the model string into a Model struct" do
      agent = Agent.new("anthropic:claude-sonnet-4")

      assert %Model{provider: :anthropic, model: "claude-sonnet-4"} = agent.model
    end

    test "carries the documented defaults" do
      agent = Agent.new("openai:gpt-4o")

      assert agent.output_type == :string
      assert agent.structured_output == []
      assert agent.retries == 1
      assert agent.end_strategy == :early
      assert agent.parallel_tool_calls == false
      assert agent.tools == []
      assert agent.plugins == []
      assert agent.hooks == []
      assert agent.fallback == []
      assert agent.model_settings == %{}
      assert agent.permissions == nil
      assert agent.enable_todos == false
    end

    test "every documented scalar option reaches the struct" do
      # `:enable_todos` was the one option `new/2` accepted, documented and
      # then dropped on the floor, leaving todo injection unreachable through
      # the public API. The sweep is here so the next added option is caught.
      opts = [
        output_type: :map,
        structured_output: [mode: :tool_call],
        instructions: "i",
        system_prompt: "s",
        deps_type: MapSet,
        name: "n",
        model_settings: %{temperature: 0.1},
        retries: 7,
        enable_todos: true,
        end_strategy: :exhaustive,
        behaviour_module: MapSet,
        parallel_tool_calls: true
      ]

      agent = Agent.new("openai:gpt-4o", opts)

      for {key, value} <- opts do
        assert Map.fetch!(agent, key) == value, "#{key} did not reach the struct"
      end
    end

    test "each agent gets a distinct generated name" do
      # Names key the agent registry and the per-agent protected-deps carve-out,
      # so a constant here would silently collapse two agents into one.
      names = for _ <- 1..3, do: Agent.new("openai:gpt-4o").name

      assert Enum.uniq(names) == names
      assert Enum.all?(names, &String.starts_with?(&1, "agent_"))
    end

    test "an explicit name wins over the generated one" do
      assert Agent.new("openai:gpt-4o", name: "researcher").name == "researcher"
    end

    test "fallback model strings are parsed into Model structs" do
      agent = Agent.new("openai:gpt-4o", fallback: ["anthropic:claude-sonnet-4"])

      assert [%Model{provider: :anthropic, model: "claude-sonnet-4"}] = agent.fallback
    end
  end

  describe "new/2 tool parsing" do
    test "captures become Tool structs" do
      agent = Agent.new("openai:gpt-4o", tools: [&__MODULE__.sample_tool_fn/2])

      assert [%Tool{name: "sample_tool_fn"}] = agent.tools
    end

    test "an existing Tool struct passes through untouched" do
      tool = Tool.from_function(&__MODULE__.sample_tool_fn/2, name: "custom")

      assert Agent.new("openai:gpt-4o", tools: [tool]).tools == [tool]
    end

    test "a bare tool module keeps the approval flag it declares" do
      # `tools: [Nous.Tools.Bash]` is the form the guides use. Dropping the
      # module's `requires_approval: true` here is exactly how an ungated shell
      # reached the runner before; the approval gate reads this field.
      assert [%Tool{name: "bash", requires_approval: true}] =
               Agent.new("openai:gpt-4o", tools: [Nous.Tools.Bash]).tools
    end

    test "mixed tool forms are all normalised" do
      agent =
        Agent.new("openai:gpt-4o",
          tools: [&__MODULE__.sample_tool_fn/2, Nous.Tools.Bash]
        )

      assert Enum.map(agent.tools, & &1.name) == ["sample_tool_fn", "bash"]
      assert Enum.all?(agent.tools, &match?(%Tool{}, &1))
    end
  end

  # `ensure_skills_plugin/2` only inspects the list, so a bare directory name
  # is enough here; loading is the plugin's job, not `new/2`'s.
  describe "new/2 skills wiring" do
    test "configuring skills appends the Skills plugin" do
      agent = Agent.new("openai:gpt-4o", skills: ["priv/skills"])

      assert agent.skills == ["priv/skills"]
      assert agent.plugins == [Nous.Plugins.Skills]
    end

    test "an explicitly listed Skills plugin is not duplicated" do
      agent =
        Agent.new("openai:gpt-4o", skills: ["priv/skills"], plugins: [Nous.Plugins.Skills])

      assert agent.plugins == [Nous.Plugins.Skills]
    end

    test "the Skills plugin is appended after the caller's own plugins" do
      agent = Agent.new("openai:gpt-4o", skills: ["priv/skills"], plugins: [SamplePlugin])

      assert agent.plugins == [SamplePlugin, Nous.Plugins.Skills]
    end

    test "skill_dirs merge into skills and also switch the plugin on" do
      agent = Agent.new("openai:gpt-4o", skills: ["a"], skill_dirs: ["b"])

      assert agent.skills == ["a", "b"]
      assert agent.plugins == [Nous.Plugins.Skills]
    end

    test "skill_dirs alone are enough" do
      agent = Agent.new("openai:gpt-4o", skill_dirs: ["b"])

      assert agent.skills == ["b"]
      assert agent.plugins == [Nous.Plugins.Skills]
    end

    test "no skills means no Skills plugin" do
      assert Agent.new("openai:gpt-4o", plugins: [SamplePlugin]).plugins == [SamplePlugin]
    end
  end

  describe "run/3 input dispatch" do
    setup do
      ModelDispatcher.put_dispatcher(EchoDispatcher)
      :ok
    end

    test "a keyword :messages input is sent to the provider as given" do
      messages = [Message.system("BE TERSE"), Message.user("hi")]

      assert {:ok, result} = Agent.run(Agent.new("openai:test-model"), messages: messages)
      assert result.output == "ok"

      assert_received {:dispatched_messages, dispatched}
      # The prompt-building path is skipped entirely for this input form: no
      # extra system turn, no reordering.
      assert Enum.map(dispatched, &{&1.role, &1.content}) ==
               [{:system, "BE TERSE"}, {:user, "hi"}]
    end

    test "a :context input without a prompt is refused rather than guessed at" do
      assert Agent.run(Agent.new("openai:test-model"), context: %Nous.Agent.Context{}) ==
               {:error, :prompt_required_with_context}

      refute_received {:dispatched_messages, _}
    end

    test "a keyword input carrying neither messages nor context is invalid" do
      assert Agent.run(Agent.new("openai:test-model"), deps: %{}) == {:error, :invalid_input}

      refute_received {:dispatched_messages, _}
    end

    test "a string prompt becomes a user turn" do
      assert {:ok, _} = Agent.run(Agent.new("openai:test-model"), "what is 2+2?")

      assert_received {:dispatched_messages, dispatched}
      assert Enum.map(dispatched, & &1.role) == [:user]
      assert hd(dispatched).content == "what is 2+2?"
    end
  end
end
