defmodule Nous.Plugins.SkillsTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Skill}
  alias Nous.Agent.Context
  alias Nous.Message.ContentPart
  alias Nous.Plugins.Skills

  defmodule TestSkill do
    use Nous.Skill, tags: [:test], group: :testing

    @impl true
    def name, do: "plugin_test_skill"

    @impl true
    def description, do: "Test skill for plugin integration"

    @impl true
    def instructions(_agent, _ctx), do: "You are a test specialist."

    @impl true
    def match?(input), do: String.contains?(input, "test")
  end

  defmodule AutoSkill do
    @behaviour Nous.Skill

    @impl true
    def name, do: "auto_skill"
    @impl true
    def description, do: "Auto-activated skill"
    @impl true
    def instructions(_, _), do: "Auto instructions"
  end

  defp make_agent(skills) do
    %Agent{
      model: Nous.Model.parse("openai:gpt-4"),
      skills: skills,
      plugins: []
    }
  end

  defp make_ctx(opts \\ []) do
    %Context{
      deps: Keyword.get(opts, :deps, %{}),
      messages: Keyword.get(opts, :messages, [])
    }
  end

  describe "init/2" do
    test "resolves skills and stores registry in deps" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())

      assert ctx.deps[:skill_registry] != nil
      assert Nous.Skill.Registry.get(ctx.deps[:skill_registry], "plugin_test_skill") != nil
    end

    test "does nothing when no skills configured" do
      agent = make_agent([])
      ctx = make_ctx()
      result = Skills.init(agent, ctx)
      assert result == ctx
    end

    test "auto-activates skills with auto activation" do
      auto_skill = %Skill{
        name: "auto_test",
        description: "Auto skill",
        instructions: "Auto instructions",
        activation: :auto,
        source: :inline,
        status: :loaded
      }

      agent = make_agent([auto_skill])
      ctx = Skills.init(agent, make_ctx())

      registry = ctx.deps[:skill_registry]
      assert Nous.Skill.Registry.active?(registry, "auto_test")
    end
  end

  describe "system_prompt/2" do
    test "returns instructions from active skills" do
      skill = %Skill{
        name: "prompt_test",
        description: "Test",
        instructions: "Test prompt instructions",
        activation: :auto,
        source: :inline,
        status: :loaded
      }

      agent = make_agent([skill])
      ctx = Skills.init(agent, make_ctx())
      prompt = Skills.system_prompt(agent, ctx)

      assert prompt != nil
      assert String.contains?(prompt, "Test prompt instructions")
      assert String.contains?(prompt, "prompt_test")
    end

    test "returns nil when no active skills" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())
      # TestSkill has :on_match activation, not :auto, so it's not active
      prompt = Skills.system_prompt(agent, ctx)
      assert prompt == nil
    end

    test "returns nil when no registry" do
      agent = make_agent([])
      ctx = make_ctx()
      assert Skills.system_prompt(agent, ctx) == nil
    end
  end

  describe "tools/2" do
    test "returns empty list when no active skills" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())
      assert Skills.tools(agent, ctx) == []
    end

    test "returns empty when no registry" do
      agent = make_agent([])
      assert Skills.tools(agent, make_ctx()) == []
    end
  end

  describe "before_request/3" do
    test "auto-activates matching skills based on user message" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())

      # Add a user message that matches the skill
      message = %Nous.Message{role: :user, content: "write a test for this function"}
      ctx = %{ctx | messages: [message]}

      {ctx, _tools} = Skills.before_request(agent, ctx, [])
      registry = ctx.deps[:skill_registry]

      assert Nous.Skill.Registry.active?(registry, "plugin_test_skill")
    end

    test "does nothing without registry" do
      agent = make_agent([])
      ctx = make_ctx()
      {result_ctx, tools} = Skills.before_request(agent, ctx, [])
      assert result_ctx == ctx
      assert tools == []
    end

    test "auto-activates matching skills from multimodal user content" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())

      message = %Nous.Message{
        role: :user,
        content: [
          ContentPart.image_url("https://example.com/screenshot.png"),
          ContentPart.text("write a test for this function")
        ]
      }

      {ctx, _tools} = Skills.before_request(agent, %{ctx | messages: [message]}, [])

      assert Nous.Skill.Registry.active?(ctx.deps[:skill_registry], "plugin_test_skill")
    end

    test "matches text split across multiple content parts" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())

      # "test" only exists once the parts are joined, so this fails if the
      # plugin ever goes back to reading a single part.
      message = %Nous.Message{
        role: :user,
        content: [ContentPart.text("write a te"), ContentPart.text("st for this")]
      }

      {ctx, _tools} = Skills.before_request(agent, %{ctx | messages: [message]}, [])

      assert Nous.Skill.Registry.active?(ctx.deps[:skill_registry], "plugin_test_skill")
    end

    test "matches only text parts, never the payload of a non-text part" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())

      # The URL contains the skill's trigger word: an implementation that
      # stringifies whole content instead of extracting text parts would
      # activate on a filename.
      message = %Nous.Message{
        role: :user,
        content: [ContentPart.image_url("https://example.com/test-screenshot.png")]
      }

      {result_ctx, tools} = Skills.before_request(agent, %{ctx | messages: [message]}, [])

      refute Nous.Skill.Registry.active?(result_ctx.deps[:skill_registry], "plugin_test_skill")
      assert tools == []
    end

    test "skips a text-free message and matches the previous user message" do
      agent = make_agent([TestSkill])
      ctx = Skills.init(agent, make_ctx())

      # Nous.Message.extract_text/1 yields "" for the image-only message, and
      # "" is truthy — without the conversion back to nil the search stops
      # there and the earlier, matching message is never seen.
      messages = [
        %Nous.Message{role: :user, content: "write a test for this function"},
        %Nous.Message{
          role: :user,
          content: [ContentPart.image_url("https://example.com/screenshot.png")]
        }
      ]

      {ctx, _tools} = Skills.before_request(agent, %{ctx | messages: messages}, [])

      assert Nous.Skill.Registry.active?(ctx.deps[:skill_registry], "plugin_test_skill")
    end
  end
end
