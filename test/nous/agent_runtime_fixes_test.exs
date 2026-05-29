defmodule Nous.AgentRuntimeFixesTest do
  @moduledoc """
  Regression tests for runtime correctness bugs:
  - per-run :model_settings override was silently ignored
  - AgentServer added the user message to the context twice per turn
  """
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, AgentServer, Usage}

  defmodule CapturingDispatcher do
    @moduledoc false

    def request(_model, messages, settings) do
      Elixir.Agent.update(__MODULE__.Store, fn s ->
        %{s | messages: messages, settings: settings}
      end)

      {:ok, text_response("ok")}
    end

    def request_stream(_m, _ms, _s), do: {:ok, []}
    def count_tokens(_messages), do: 0

    defp text_response(text) do
      Nous.Message.from_legacy(%{
        parts: [{:text, text}],
        usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      })
    end
  end

  setup do
    {:ok, _} =
      Elixir.Agent.start_link(fn -> %{messages: [], settings: %{}} end,
        name: CapturingDispatcher.Store
      )

    Application.put_env(:nous, :model_dispatcher, CapturingDispatcher)
    on_exit(fn -> Application.delete_env(:nous, :model_dispatcher) end)
    :ok
  end

  describe "per-run :model_settings override" do
    test "merges over the agent's model_settings for this run" do
      agent = Agent.new("openai:test-model", model_settings: %{temperature: 0.1})

      assert {:ok, _result} =
               AgentRunner.run(agent, "hi", model_settings: %{temperature: 0.9, max_tokens: 42})

      settings = Elixir.Agent.get(CapturingDispatcher.Store, & &1.settings)
      assert settings[:temperature] == 0.9
      assert settings[:max_tokens] == 42
    end
  end

  describe "AgentServer does not double-add the user message" do
    test "the user prompt appears exactly once in the conversation" do
      session = "double_add_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session,
          agent_config: %{model: "openai:test-model", instructions: "Be helpful"}
        )

      AgentServer.send_message(pid, "hello once")
      wait_for_assistant(pid)

      history = AgentServer.get_history(pid)
      user_msgs = Enum.filter(history, &(&1.role == :user))

      assert length(user_msgs) == 1
      assert hd(user_msgs).content == "hello once"
    end
  end

  defp wait_for_assistant(pid, attempts \\ 100)

  defp wait_for_assistant(_pid, 0), do: flunk("agent never produced an assistant response")

  defp wait_for_assistant(pid, attempts) do
    history = AgentServer.get_history(pid)

    if Enum.any?(history, &(&1.role == :assistant)) do
      :ok
    else
      Process.sleep(20)
      wait_for_assistant(pid, attempts - 1)
    end
  end
end
