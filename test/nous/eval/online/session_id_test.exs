Code.require_file("online_helpers.exs", __DIR__)

defmodule Nous.Eval.Online.SessionIdTest do
  # async: false - AgentServer turns run in the server's tasks, so the
  # model stub lives in the application env.
  use ExUnit.Case, async: false

  import Nous.Eval.OnlineHelpers

  alias Nous.AgentServer

  @moduletag :capture_log

  setup do
    install_stub()
    test = self()
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:nous, :agent, :run, :start], &__MODULE__.forward/4, test)
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def forward(_event, _measurements, metadata, pid), do: send(pid, {:run_start, metadata})

  defp starts(acc \\ []) do
    receive do
      {:run_start, meta} -> starts([meta | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "run.start carries deps[:session_id]; a sub-agent reports its root's session" do
    assert {:ok, _} = run!("SUB go", deps: %{session_id: "sess-42"})

    assert [root, sub] = starts()
    assert Map.has_key?(root, :session_id)
    assert root.session_id == "sess-42"
    assert sub.parent_agent_run_id == root.agent_run_id
    assert sub.session_id == "sess-42"
  end

  test "session_id is nil without one, and only strings count" do
    assert {:ok, _} = run!("hello")
    assert {:ok, _} = run!("hello", deps: %{session_id: :not_a_string})
    assert [%{session_id: nil}, %{session_id: nil}] = starts()
  end

  test "every AgentServer turn reports the server's session" do
    session = "server-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      AgentServer.start_link(
        session_id: session,
        agent_config: %{model: "openai:gpt-4o-mini", instructions: "Help.", tools: []},
        pubsub: nil,
        inactivity_timeout: :infinity
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for prompt <- ["first", "second"] do
      :ok = AgentServer.send_message(pid, prompt)
      assert_receive {:run_start, %{session_id: ^session}}, 2_000
    end
  end
end
