defmodule Nous.Telemetry.AgentServerEventsTest do
  # async: false — an AgentServer turn runs in a task under the server, which
  # no test process is a `$caller` of, so the model stub goes through the
  # application environment. Its run events are picked out by model name (no
  # other test runs concurrently with an async: false module).
  use ExUnit.Case, async: false

  alias Nous.{AgentServer, Message, Usage}

  @moduletag :capture_log

  defmodule Dispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      {:ok,
       Message.assistant("turn reply",
         metadata: %{usage: %Usage{input_tokens: 2, output_tokens: 2, total_tokens: 4}}
       )}
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_used}
    def count_tokens(_messages), do: 1
  end

  setup do
    previous = Application.get_env(:nous, :model_dispatcher)
    Application.put_env(:nous, :model_dispatcher, Dispatcher)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nous, :model_dispatcher, previous),
        else: Application.delete_env(:nous, :model_dispatcher)
    end)

    :ok
  end

  def forward(event, _measurements, %{model_name: model} = metadata, {pid, model}) do
    send(pid, {:server_event, event, metadata})
  end

  def forward(_event, _measurements, _metadata, _config), do: :ok

  test "every AgentServer turn is its own root run with the ids minted inside the turn" do
    session_id = "telemetry_#{System.unique_integer([:positive])}"
    handler = "agent-server-events-#{session_id}"

    :telemetry.attach_many(
      handler,
      [
        [:nous, :agent, :run, :start],
        [:nous, :agent, :run, :stop],
        [:nous, :agent, :model, :stop]
      ],
      &__MODULE__.forward/4,
      {self(), "gpt-4"}
    )

    {:ok, pid} =
      AgentServer.start_link(
        session_id: session_id,
        agent_config: %{model: "openai:gpt-4", instructions: "Be helpful", tools: []},
        pubsub: nil,
        inactivity_timeout: :infinity
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    turns =
      for prompt <- ["first", "second"] do
        :ok = AgentServer.send_message(pid, prompt)
        assert_receive {:server_event, [:nous, :agent, :run, :start], start}, 2_000
        assert_receive {:server_event, [:nous, :agent, :model, :stop], model_stop}, 2_000
        assert_receive {:server_event, [:nous, :agent, :run, :stop], stop}, 2_000
        {start, model_stop, stop}
      end

    GenServer.stop(pid)

    for {start, model_stop, stop} <- turns do
      assert start.trace_id =~ ~r/\A[0-9a-f]{32}\z/
      assert start.agent_run_id =~ ~r/\A[0-9a-f]{16}\z/
      assert start.parent_agent_run_id == nil
      assert model_stop.agent_run_id == start.agent_run_id
      assert stop.agent_run_id == start.agent_run_id
    end

    [{first, _, _}, {second, _, _}] = turns
    assert first.agent_run_id != second.agent_run_id
    assert first.trace_id != second.trace_id
  end
end
