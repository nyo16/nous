defmodule Nous.AgentRunner.RequestDispatchTest do
  use ExUnit.Case, async: true

  alias Nous.{Tool, ToolSchema}
  alias Nous.AgentRunner.RequestDispatch
  alias Nous.Messages.Gemini

  defp sample_tool do
    %Tool{
      name: "search",
      description: "Search the index",
      function: fn _, _ -> {:ok, "n/a"} end,
      parameters: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"],
        "additionalProperties" => false
      }
    }
  end

  describe "convert_tools_for_provider/2" do
    test "openai-compatible providers get the OpenAI function envelope" do
      tool = sample_tool()

      assert RequestDispatch.convert_tools_for_provider(:openai, [tool]) ==
               [Tool.to_openai_schema(tool)]
    end

    test "anthropic gets the atom-keyed input_schema form" do
      tool = sample_tool()

      assert RequestDispatch.convert_tools_for_provider(:anthropic, [tool]) ==
               [ToolSchema.to_anthropic(tool)]
    end

    test "gemini gets bare function declarations, not the OpenAI envelope" do
      tool = sample_tool()

      assert [declaration] = RequestDispatch.convert_tools_for_provider(:gemini, [tool])
      assert declaration == ToolSchema.to_gemini(tool)

      # The regression this guards: the runner used to fall through to the
      # OpenAI clause, so a %{"type" => "function", "function" => …} envelope
      # ended up inside "functionDeclarations" on the wire.
      assert declaration["name"] == "search"
      refute Map.has_key?(declaration, "type")
      refute Map.has_key?(declaration, "function")
    end

    test "vertex_ai shares the Gemini declaration format" do
      tool = sample_tool()

      assert RequestDispatch.convert_tools_for_provider(:vertex_ai, [tool]) ==
               [ToolSchema.to_gemini(tool)]
    end

    test "declarations are directly consumable by the Gemini wire builder" do
      declarations = RequestDispatch.convert_tools_for_provider(:gemini, [sample_tool()])

      assert [%{"functionDeclarations" => [declaration]}] = Gemini.build_tools(declarations, nil)
      assert declaration["name"] == "search"
      refute Map.has_key?(declaration, "function")
    end
  end

  describe "rebuild_tool_settings/4" do
    test "returns settings untouched when the provider is unchanged" do
      settings = %{temperature: 0.5, tools: [%{"type" => "function"}]}

      assert RequestDispatch.rebuild_tool_settings(:openai, :openai, settings, [sample_tool()]) ==
               settings
    end

    test "re-converts tool schemas for the target provider" do
      tool = sample_tool()
      settings = %{temperature: 0.5, tools: [Tool.to_openai_schema(tool)]}

      rebuilt = RequestDispatch.rebuild_tool_settings(:gemini, :openai, settings, [tool])

      assert rebuilt.temperature == 0.5
      assert rebuilt.tools == [ToolSchema.to_gemini(tool)]
    end

    test "drops the previous provider's tool_choice and response_format" do
      settings = %{
        temperature: 0.5,
        tools: [%{"type" => "function"}],
        tool_choice: "auto",
        response_format: %{"type" => "json_object"}
      }

      assert RequestDispatch.rebuild_tool_settings(:anthropic, :openai, settings, []) ==
               %{temperature: 0.5}
    end
  end

  describe "rebuild_settings_for_model/4" do
    # An SGLang agent's output_type adds `:json_schema`. Falling back to
    # llamacpp with tools, that key must not survive: llama.cpp cannot combine
    # a schema grammar with the tool-call grammar, and the provider refuses
    # the pair with a ConfigurationError, failing a valid fallback.
    test "drops the source provider's structured-output keys before re-injecting" do
      agent =
        Nous.Agent.new("sglang:qwen",
          base_url: "http://localhost:30000/v1",
          tools: [sample_tool()],
          output_type: %{city: :string}
        )

      source_settings =
        Nous.AgentRunner.PromptAssembly.inject_structured_output_settings(
          agent,
          %{tools: [Tool.to_openai_schema(sample_tool())]},
          [sample_tool()]
        )

      assert source_settings[:json_schema]

      target = Nous.Model.parse("llamacpp:local")

      settings =
        RequestDispatch.rebuild_settings_for_model(
          target,
          source_settings,
          [sample_tool()],
          agent
        )

      refute Map.has_key?(settings, :json_schema)
      refute Map.has_key?(settings, :response_format)

      assert "__structured_output__" in Enum.map(settings.tools, & &1["function"]["name"])
      assert "search" in Enum.map(settings.tools, & &1["function"]["name"])
    end
  end
end
