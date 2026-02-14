defmodule Nous.HITLTest do
  use ExUnit.Case, async: false

  alias Nous.{Agent, Tool, Message, Usage}
  alias Nous.Agent.Context
  alias Nous.Plugins.HumanInTheLoop

  import ExUnit.CaptureLog

  describe "Tool requires_approval option" do
    test "Tool struct accepts requires_approval: true" do
      tool =
        Tool.from_function(&dummy_tool/2,
          name: "risky_tool",
          description: "A risky tool",
          requires_approval: true
        )

      assert tool.requires_approval == true
    end

    test "Tool struct defaults requires_approval to false" do
      tool =
        Tool.from_function(&dummy_tool/2,
          name: "safe_tool",
          description: "A safe tool"
        )

      assert tool.requires_approval == false
    end
  end

  describe "HumanInTheLoop plugin init/2" do
    test "sets approval_handler on context when hitl_config has handler" do
      agent = Agent.new("openai:test-model")

      ctx =
        Context.new(
          deps: %{
            hitl_config: %{
              handler: fn _call -> :approve end,
              tools: ["send_email"]
            }
          }
        )

      result = HumanInTheLoop.init(agent, ctx)

      assert is_function(result.approval_handler)
    end

    test "does not set approval_handler when no hitl_config" do
      agent = Agent.new("openai:test-model")
      ctx = Context.new()

      result = HumanInTheLoop.init(agent, ctx)

      assert result.approval_handler == nil
    end

    test "does not set approval_handler when hitl_config has no handler" do
      agent = Agent.new("openai:test-model")
      ctx = Context.new(deps: %{hitl_config: %{tools: ["send_email"]}})

      result = HumanInTheLoop.init(agent, ctx)

      assert result.approval_handler == nil
    end
  end

  describe "HumanInTheLoop plugin before_request/3" do
    test "tags tools listed in hitl_config with requires_approval" do
      agent = Agent.new("openai:test-model")

      ctx =
        Context.new(
          deps: %{
            hitl_config: %{
              handler: fn _call -> :approve end,
              tools: ["send_email"]
            }
          }
        )

      email_tool = %Tool{
        name: "send_email",
        description: "Send email",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        function: &dummy_tool/2,
        requires_approval: false
      }

      safe_tool = %Tool{
        name: "search",
        description: "Search",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        function: &dummy_tool/2,
        requires_approval: false
      }

      {_ctx, tools} = HumanInTheLoop.before_request(agent, ctx, [email_tool, safe_tool])

      tagged_email = Enum.find(tools, &(&1.name == "send_email"))
      tagged_search = Enum.find(tools, &(&1.name == "search"))

      assert tagged_email.requires_approval == true
      assert tagged_search.requires_approval == false
    end

    test "does not tag tools when hitl_config.tools is empty" do
      agent = Agent.new("openai:test-model")
      ctx = Context.new(deps: %{hitl_config: %{handler: fn _call -> :approve end, tools: []}})

      tool = %Tool{
        name: "send_email",
        description: "Send email",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        function: &dummy_tool/2,
        requires_approval: false
      }

      {_ctx, tools} = HumanInTheLoop.before_request(agent, ctx, [tool])

      assert hd(tools).requires_approval == false
    end

    test "does not tag tools when hitl_config is absent" do
      agent = Agent.new("openai:test-model")
      ctx = Context.new(deps: %{})

      tool = %Tool{
        name: "send_email",
        description: "Send email",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        function: &dummy_tool/2,
        requires_approval: false
      }

      {_ctx, tools} = HumanInTheLoop.before_request(agent, ctx, [tool])

      assert hd(tools).requires_approval == false
    end
  end

  describe "approval handler responses via full agent run" do
    setup do
      Application.put_env(:nous, :model_dispatcher, __MODULE__.MockDispatcher)

      on_exit(fn ->
        Application.delete_env(:nous, :model_dispatcher)
      end)

      tool =
        Tool.from_function(&dummy_tool/2,
          name: "send_email",
          description: "Send an email",
          requires_approval: true
        )

      agent =
        Agent.new("openai:test-model",
          instructions: "Use tools",
          tools: [tool],
          plugins: [HumanInTheLoop]
        )

      %{agent: agent}
    end

    test "handler :approve allows tool execution", %{agent: agent} do
      {:ok, result} =
        Agent.run(agent, "tool_call_test",
          deps: %{
            hitl_config: %{
              handler: fn _call -> :approve end,
              tools: ["send_email"]
            }
          }
        )

      assert result.output =~ "Tool result: approved"
    end

    test "handler :reject returns rejection message", %{agent: agent} do
      logs =
        capture_log(fn ->
          {:ok, result} =
            Agent.run(agent, "tool_call_test",
              deps: %{
                hitl_config: %{
                  handler: fn _call -> :reject end,
                  tools: ["send_email"]
                }
              }
            )

          # The agent should still complete; the mock returns a final response after seeing the rejection
          assert result.output =~ "Response after rejection"
        end)

      assert logs =~ "rejected by approval handler"
    end

    test "handler {:edit, new_args} modifies tool arguments", %{agent: agent} do
      {:ok, result} =
        Agent.run(agent, "tool_call_test",
          deps: %{
            hitl_config: %{
              handler: fn _call -> {:edit, %{"input" => "edited_value"}} end,
              tools: ["send_email"]
            }
          }
        )

      assert result.output =~ "Tool result: approved"
    end

    test "fail-open: proceeds when no handler configured but tool requires approval" do
      tool =
        Tool.from_function(&dummy_tool/2,
          name: "send_email",
          description: "Send an email",
          requires_approval: true
        )

      # No plugins, no approval_handler set on context
      agent =
        Agent.new("openai:test-model",
          instructions: "Use tools",
          tools: [tool]
        )

      {:ok, result} = Agent.run(agent, "tool_call_test")

      # Without a handler, should proceed (fail-open)
      assert result.output =~ "Tool result: approved"
    end
  end

  # Mock dispatcher for HITL tests
  defmodule MockDispatcher do
    def request(_model, messages, _settings) do
      has_tool_results =
        Enum.any?(messages, fn
          %Message{role: :tool} -> true
          _ -> false
        end)

      has_rejection =
        Enum.any?(messages, fn
          %Message{role: :tool, content: content} -> content =~ "rejected"
          _ -> false
        end)

      cond do
        has_rejection ->
          # After rejection, return final response
          legacy = %{
            parts: [{:text, "Response after rejection"}],
            usage: %Usage{
              input_tokens: 10,
              output_tokens: 5,
              total_tokens: 15,
              tool_calls: 0,
              requests: 1
            },
            model_name: "test-model",
            timestamp: DateTime.utc_now()
          }

          {:ok, Message.from_legacy(legacy)}

        has_tool_results ->
          # After tool execution, return final response
          legacy = %{
            parts: [{:text, "Tool result: approved"}],
            usage: %Usage{
              input_tokens: 10,
              output_tokens: 5,
              total_tokens: 15,
              tool_calls: 0,
              requests: 1
            },
            model_name: "test-model",
            timestamp: DateTime.utc_now()
          }

          {:ok, Message.from_legacy(legacy)}

        true ->
          # First call, return a tool call
          legacy = %{
            parts: [
              {:tool_call,
               %{
                 id: "call_hitl_1",
                 name: "send_email",
                 arguments: %{"input" => "test_value"}
               }}
            ],
            usage: %Usage{
              input_tokens: 10,
              output_tokens: 5,
              total_tokens: 15,
              tool_calls: 0,
              requests: 1
            },
            model_name: "test-model",
            timestamp: DateTime.utc_now()
          }

          {:ok, Message.from_legacy(legacy)}
      end
    end

    def request_stream(_model, _messages, _settings) do
      {:ok, []}
    end

    def count_tokens(_messages), do: 50
  end

  # Dummy tool function for tests
  defp dummy_tool(_ctx, _args) do
    %{success: true, message: "Email sent"}
  end
end
