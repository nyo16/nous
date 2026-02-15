defmodule Nous.PluginTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Plugin, Tool}
  alias Nous.Agent.Context
  alias Nous.Message

  # A plugin that implements all callbacks
  defmodule FullPlugin do
    @behaviour Nous.Plugin

    @impl true
    def init(_agent, ctx) do
      Context.merge_deps(ctx, %{full_plugin_init: true})
    end

    @impl true
    def tools(_agent, _ctx) do
      [
        %Tool{
          name: "full_plugin_tool",
          description: "A tool from FullPlugin",
          parameters: %{"type" => "object", "properties" => %{}, "required" => []},
          function: fn _ctx, _args -> "ok" end
        }
      ]
    end

    @impl true
    def system_prompt(_agent, _ctx) do
      "FullPlugin system prompt fragment"
    end

    @impl true
    def before_request(_agent, ctx, tools) do
      ctx = Context.merge_deps(ctx, %{full_plugin_before: true})

      extra_tool = %Tool{
        name: "before_request_tool",
        description: "Added by before_request",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        function: fn _ctx, _args -> "ok" end
      }

      {ctx, tools ++ [extra_tool]}
    end

    @impl true
    def after_response(_agent, _response, ctx) do
      Context.merge_deps(ctx, %{full_plugin_after: true})
    end
  end

  # A second plugin to test threading/composition
  defmodule SecondPlugin do
    @behaviour Nous.Plugin

    @impl true
    def init(_agent, ctx) do
      Context.merge_deps(ctx, %{second_plugin_init: true})
    end

    @impl true
    def tools(_agent, _ctx) do
      [
        %Tool{
          name: "second_plugin_tool",
          description: "A tool from SecondPlugin",
          parameters: %{"type" => "object", "properties" => %{}, "required" => []},
          function: fn _ctx, _args -> "ok" end
        }
      ]
    end

    @impl true
    def system_prompt(_agent, _ctx) do
      "SecondPlugin system prompt fragment"
    end

    @impl true
    def before_request(_agent, ctx, tools) do
      ctx = Context.merge_deps(ctx, %{second_plugin_before: true})
      {ctx, tools}
    end

    @impl true
    def after_response(_agent, _response, ctx) do
      Context.merge_deps(ctx, %{second_plugin_after: true})
    end
  end

  # A minimal plugin that implements no optional callbacks
  defmodule MinimalPlugin do
    @behaviour Nous.Plugin
  end

  # A plugin that only implements some callbacks
  defmodule PartialPlugin do
    @behaviour Nous.Plugin

    @impl true
    def init(_agent, ctx) do
      Context.merge_deps(ctx, %{partial_init: true})
    end

    @impl true
    def system_prompt(_agent, _ctx) do
      "PartialPlugin prompt"
    end
  end

  # A plugin whose system_prompt returns nil
  defmodule NilPromptPlugin do
    @behaviour Nous.Plugin

    @impl true
    def system_prompt(_agent, _ctx) do
      nil
    end
  end

  setup do
    agent = Agent.new("openai:test-model", instructions: "Be helpful")
    ctx = Context.new(system_prompt: "Base prompt")
    %{agent: agent, ctx: ctx}
  end

  describe "run_init/3" do
    test "threads context through all plugins", %{agent: agent, ctx: ctx} do
      result = Plugin.run_init([FullPlugin, SecondPlugin], agent, ctx)

      assert result.deps[:full_plugin_init] == true
      assert result.deps[:second_plugin_init] == true
    end

    test "skips plugins that do not implement init", %{agent: agent, ctx: ctx} do
      result = Plugin.run_init([MinimalPlugin, FullPlugin], agent, ctx)

      assert result.deps[:full_plugin_init] == true
    end

    test "returns original context with empty plugins list", %{agent: agent, ctx: ctx} do
      result = Plugin.run_init([], agent, ctx)

      assert result == ctx
    end

    test "preserves order - later plugins see earlier plugins' changes", %{agent: agent, ctx: ctx} do
      # PartialPlugin sets :partial_init, then FullPlugin sets :full_plugin_init
      result = Plugin.run_init([PartialPlugin, FullPlugin], agent, ctx)

      assert result.deps[:partial_init] == true
      assert result.deps[:full_plugin_init] == true
    end
  end

  describe "collect_tools/3" do
    test "collects tools from all plugins", %{agent: agent, ctx: ctx} do
      tools = Plugin.collect_tools([FullPlugin, SecondPlugin], agent, ctx)

      assert length(tools) == 2
      names = Enum.map(tools, & &1.name)
      assert "full_plugin_tool" in names
      assert "second_plugin_tool" in names
    end

    test "skips plugins that do not implement tools", %{agent: agent, ctx: ctx} do
      tools = Plugin.collect_tools([MinimalPlugin, FullPlugin], agent, ctx)

      assert length(tools) == 1
      assert hd(tools).name == "full_plugin_tool"
    end

    test "returns empty list with empty plugins list", %{agent: agent, ctx: ctx} do
      tools = Plugin.collect_tools([], agent, ctx)

      assert tools == []
    end

    test "returns empty list when no plugins implement tools", %{agent: agent, ctx: ctx} do
      tools = Plugin.collect_tools([MinimalPlugin, PartialPlugin], agent, ctx)

      assert tools == []
    end
  end

  describe "collect_system_prompts/3" do
    test "joins prompt fragments from all plugins", %{agent: agent, ctx: ctx} do
      result = Plugin.collect_system_prompts([FullPlugin, SecondPlugin], agent, ctx)

      assert result == "FullPlugin system prompt fragment\n\nSecondPlugin system prompt fragment"
    end

    test "skips plugins that do not implement system_prompt", %{agent: agent, ctx: ctx} do
      result = Plugin.collect_system_prompts([MinimalPlugin, FullPlugin], agent, ctx)

      assert result == "FullPlugin system prompt fragment"
    end

    test "returns nil with empty plugins list", %{agent: agent, ctx: ctx} do
      result = Plugin.collect_system_prompts([], agent, ctx)

      assert result == nil
    end

    test "returns nil when no plugins implement system_prompt", %{agent: agent, ctx: ctx} do
      result = Plugin.collect_system_prompts([MinimalPlugin], agent, ctx)

      assert result == nil
    end

    test "filters out nil prompt fragments", %{agent: agent, ctx: ctx} do
      result = Plugin.collect_system_prompts([NilPromptPlugin, FullPlugin], agent, ctx)

      assert result == "FullPlugin system prompt fragment"
    end

    test "returns nil when all fragments are nil", %{agent: agent, ctx: ctx} do
      result = Plugin.collect_system_prompts([NilPromptPlugin], agent, ctx)

      assert result == nil
    end
  end

  describe "run_before_request/4" do
    test "threads context and tools through all plugins", %{agent: agent, ctx: ctx} do
      initial_tools = [
        %Tool{
          name: "original_tool",
          description: "An original tool",
          parameters: %{"type" => "object", "properties" => %{}, "required" => []},
          function: fn _ctx, _args -> "ok" end
        }
      ]

      {result_ctx, result_tools} =
        Plugin.run_before_request([FullPlugin, SecondPlugin], agent, ctx, initial_tools)

      # Both plugins set their deps
      assert result_ctx.deps[:full_plugin_before] == true
      assert result_ctx.deps[:second_plugin_before] == true

      # FullPlugin added a tool, SecondPlugin did not remove it
      tool_names = Enum.map(result_tools, & &1.name)
      assert "original_tool" in tool_names
      assert "before_request_tool" in tool_names
    end

    test "skips plugins that do not implement before_request", %{agent: agent, ctx: ctx} do
      initial_tools = []

      {result_ctx, result_tools} =
        Plugin.run_before_request([MinimalPlugin, FullPlugin], agent, ctx, initial_tools)

      assert result_ctx.deps[:full_plugin_before] == true
      assert length(result_tools) == 1
      assert hd(result_tools).name == "before_request_tool"
    end

    test "returns original context and tools with empty plugins list", %{agent: agent, ctx: ctx} do
      initial_tools = []

      {result_ctx, result_tools} = Plugin.run_before_request([], agent, ctx, initial_tools)

      assert result_ctx == ctx
      assert result_tools == []
    end
  end

  describe "run_after_response/4" do
    test "threads context through all plugins", %{agent: agent, ctx: ctx} do
      response = Message.assistant("Test response")

      result = Plugin.run_after_response([FullPlugin, SecondPlugin], agent, response, ctx)

      assert result.deps[:full_plugin_after] == true
      assert result.deps[:second_plugin_after] == true
    end

    test "skips plugins that do not implement after_response", %{agent: agent, ctx: ctx} do
      response = Message.assistant("Test response")

      result = Plugin.run_after_response([MinimalPlugin, FullPlugin], agent, response, ctx)

      assert result.deps[:full_plugin_after] == true
    end

    test "returns original context with empty plugins list", %{agent: agent, ctx: ctx} do
      response = Message.assistant("Test response")

      result = Plugin.run_after_response([], agent, response, ctx)

      assert result == ctx
    end
  end

  describe "all optional callbacks safely skipped" do
    test "MinimalPlugin works as a no-op for every hook", %{agent: agent, ctx: ctx} do
      plugins = [MinimalPlugin]

      # run_init
      result_ctx = Plugin.run_init(plugins, agent, ctx)
      assert result_ctx == ctx

      # collect_tools
      tools = Plugin.collect_tools(plugins, agent, ctx)
      assert tools == []

      # collect_system_prompts
      prompt = Plugin.collect_system_prompts(plugins, agent, ctx)
      assert prompt == nil

      # run_before_request
      {br_ctx, br_tools} = Plugin.run_before_request(plugins, agent, ctx, [])
      assert br_ctx == ctx
      assert br_tools == []

      # run_after_response
      response = Message.assistant("test")
      ar_ctx = Plugin.run_after_response(plugins, agent, response, ctx)
      assert ar_ctx == ctx
    end
  end
end
