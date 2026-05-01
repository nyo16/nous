defmodule Nous.StructuredOutputStreamingTest do
  use ExUnit.Case, async: false

  alias Nous.{AgentRunner, Tool, Usage}

  # Reuses the same TestUser shape as the non-streaming structured output suite.
  defmodule TestUser do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc "A user with name and age."
    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:age, :integer)
    end
  end

  defmodule ScriptedDispatcher do
    @moduledoc false

    def request_stream(_model, _messages, _settings) do
      events =
        Elixir.Agent.get_and_update(
          __MODULE__.Script,
          fn [next | rest] -> {next, rest} end
        )

      {:ok, events}
    end

    def request(_, _, _), do: {:error, :not_used}
    def count_tokens(_), do: 0
  end

  setup do
    {:ok, _pid} = Elixir.Agent.start_link(fn -> [] end, name: ScriptedDispatcher.Script)
    Application.put_env(:nous, :model_dispatcher, ScriptedDispatcher)
    on_exit(fn -> Application.delete_env(:nous, :model_dispatcher) end)
    %{model: "openai:gpt-test"}
  end

  defp script(s), do: Elixir.Agent.update(ScriptedDispatcher.Script, fn _ -> s end)

  test "stream: true returns the structured output via the synthetic tool path",
       %{model: model} do
    # The synthetic tool name OutputSchema generates for TestUser
    synthetic_name = Nous.OutputSchema.tool_name_for_schema(TestUser)

    # Stream the synthetic tool call's JSON args in pieces
    iter1 = [
      {:tool_call_delta,
       [
         %{
           "index" => 0,
           "id" => "call_so",
           "function" => %{"name" => synthetic_name, "arguments" => "{\"na"}
         }
       ]},
      {:tool_call_delta, [%{"index" => 0, "function" => %{"arguments" => "me\":\"alice"}}]},
      {:tool_call_delta, [%{"index" => 0, "function" => %{"arguments" => "\",\"age\":30}"}}]},
      {:finish, "tool_calls"},
      {:usage, %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1}}
    ]

    script([iter1])

    parent = self()

    callbacks = %{
      on_llm_new_delta: fn _e, t -> send(parent, {:delta, t}) end
    }

    agent = Nous.Agent.new(model, instructions: "Extract", output_type: TestUser)

    assert {:ok, result} =
             AgentRunner.run(agent, "alice 30", stream: true, callbacks: callbacks)

    assert %TestUser{name: "alice", age: 30} = result.output
    # Synthetic tool call is filtered, so usage.tool_calls is 0 (it's NOT executed)
    assert result.usage.tool_calls == 0
    # Single iteration — the synthetic tool stops the loop
    assert result.iterations == 1
    # No text deltas — the model wrote JSON to the synthetic tool, not plain text
    refute_received {:delta, _}
  end

  test "stream: true with a real tool alongside structured output still works",
       %{model: model} do
    synthetic_name = Nous.OutputSchema.tool_name_for_schema(TestUser)

    real_tool =
      Tool.from_function(fn _ctx, %{"q" => q} -> %{out: "got:#{q}"} end,
        name: "lookup",
        description: "Look up"
      )

    iter1 = [
      {:tool_call_delta,
       [
         %{
           "index" => 0,
           "id" => "call_real",
           "function" => %{"name" => "lookup", "arguments" => "{\"q\":\"x\"}"}
         }
       ]},
      {:finish, "tool_calls"},
      {:usage, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1}}
    ]

    iter2 = [
      {:tool_call_delta,
       [
         %{
           "index" => 0,
           "id" => "call_so",
           "function" => %{
             "name" => synthetic_name,
             "arguments" => "{\"name\":\"bob\",\"age\":42}"
           }
         }
       ]},
      {:finish, "tool_calls"},
      {:usage, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1}}
    ]

    script([iter1, iter2])

    agent =
      Nous.Agent.new(model,
        instructions: "Extract",
        output_type: TestUser,
        tools: [real_tool]
      )

    assert {:ok, result} = AgentRunner.run(agent, "go", stream: true)
    assert %TestUser{name: "bob", age: 42} = result.output
    assert result.iterations == 2
    # Only the real tool executed; synthetic doesn't count
    assert result.usage.tool_calls == 1
  end
end
