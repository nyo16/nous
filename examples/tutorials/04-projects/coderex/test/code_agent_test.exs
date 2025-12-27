defmodule Coderex.CodeAgentTest do
  use ExUnit.Case
  alias Coderex.CodeAgent

  describe "new/2" do
    test "creates agent with default settings" do
      agent = CodeAgent.new("anthropic:claude-haiku-4-5-20251001")

      assert agent.model.provider == :anthropic
      assert agent.model.model == "claude-haiku-4-5-20251001"
      assert agent.instructions =~ "expert software engineer"
      assert length(agent.tools) == 9
    end

    test "appends extra instructions" do
      agent = CodeAgent.new("anthropic:claude-haiku-4-5-20251001",
        instructions: "Focus on Elixir"
      )

      assert agent.instructions =~ "Focus on Elixir"
      assert agent.instructions =~ "Additional Instructions"
    end

    test "includes all core tools" do
      agent = CodeAgent.new("anthropic:claude-haiku-4-5-20251001")

      tool_names = Enum.map(agent.tools, & &1.name)

      assert "read_file" in tool_names
      assert "write_file" in tool_names
      assert "edit_file" in tool_names
      assert "list_files" in tool_names
      assert "search_files" in tool_names
      assert "file_info" in tool_names
      assert "create_directory" in tool_names
      assert "delete_file" in tool_names
      assert "execute_command" in tool_names
    end
  end

  describe "run/3 error handling" do
    setup do
      # Clear API key for tests
      original_key = System.get_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if original_key do
          System.put_env("ANTHROPIC_API_KEY", original_key)
        end
      end)

      :ok
    end

    test "returns error when Anthropic API key is missing" do
      agent = CodeAgent.new("anthropic:claude-haiku-4-5-20251001")

      result = CodeAgent.run(agent, "test prompt")

      assert {:error, message} = result
      assert message =~ "ANTHROPIC_API_KEY"
      assert message =~ "not set"
    end

    test "returns error when OpenAI API key is missing" do
      agent = CodeAgent.new("openai:gpt-4o")

      result = CodeAgent.run(agent, "test prompt")

      assert {:error, message} = result
      assert message =~ "OPENAI_API_KEY"
    end

    # Google provider not supported yet in Nous
    # test "returns error when Google API key is missing" do
    #   agent = CodeAgent.new("google:gemini-pro")
    #   result = CodeAgent.run(agent, "test prompt")
    #   assert {:error, message} = result
    #   assert message =~ "GOOGLE_API_KEY"
    # end
  end

  describe "run_stream/3 error handling" do
    setup do
      original_key = System.get_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if original_key do
          System.put_env("ANTHROPIC_API_KEY", original_key)
        end
      end)

      :ok
    end

    test "returns error when API key is missing" do
      agent = CodeAgent.new("anthropic:claude-haiku-4-5-20251001")

      result = CodeAgent.run_stream(agent, "test prompt")

      assert {:error, message} = result
      assert message =~ "ANTHROPIC_API_KEY"
    end
  end
end
