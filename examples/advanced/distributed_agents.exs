#!/usr/bin/env elixir

# Nous AI - Distributed Agents
# Supervised Nous agents spread across two BEAM nodes.
#
# This is the thing you cannot do in a Python or JavaScript agent framework:
# a second runtime is started from inside the script, the same agent code is
# shipped to it, agents run there under a real supervisor, and the calling
# node kills, monitors, and calls those remote processes as if they were local.
#
# What it demonstrates:
#   1. Bootstrapping distribution + a peer node from a plain `mix run`
#   2. Nous.AgentDynamicSupervisor / Nous.AgentRegistry on BOTH nodes
#   3. Killing an agent ACROSS THE NETWORK and watching its supervisor
#      restart it while its siblings keep running untouched
#   4. Recovering the killed agent's conversation state through
#      Nous.Persistence + Nous.Agent.Context.serialize/1 + deserialize/1
#
# No API key required. No LLM call, no outbound network of any kind: the
# agents' "work" is a local tool call (a SHA-256 fingerprint) executed on the
# node that owns the agent, and the resulting turn is written into the agent's
# context directly. Inference is not the point here - supervision is.

require Logger

IO.puts("=== Nous AI - Distributed Agents Demo ===\n")

# Supervisor crash reports and AgentServer lifecycle logs would drown the
# narrative below. Silence them and narrate the same facts ourselves, with
# pids you can check.
Logger.configure(level: :emergency)
IO.puts("(Logger silenced to :emergency so the narrative below reads cleanly.)")

# ============================================================================
# Step 1 - Bring up distribution and a second node
# ============================================================================

IO.puts("\n--- Step 1: Cluster bootstrap ---")

suffix = System.pid()
cookie = :nous_distributed_agents_demo

start_result =
  if Node.alive?() do
    {:ok, :already_alive}
  else
    case Node.start(:"nous_primary_#{suffix}@127.0.0.1", :longnames) do
      {:ok, _pid} ->
        Node.set_cookie(cookie)
        {:ok, :started}

      {:error, reason} ->
        {:error, reason}
    end
  end

case start_result do
  {:ok, _} ->
    :ok

  {:error, reason} ->
    IO.puts("""
    Could not start Erlang distribution: #{inspect(reason)}

    This example needs epmd (the Erlang Port Mapper Daemon) and a resolvable
    127.0.0.1. Start epmd with `epmd -daemon` and re-run:

        mix run examples/advanced/distributed_agents.exs

    Skipping the demo.
    """)

    System.halt(0)
end

IO.puts("primary node : #{Node.self()}")
IO.puts("cookie       : #{Node.get_cookie()}")

# :peer replaces the old :slave module on OTP 25+. `args` seeds the child VM
# with our cookie so it can join the cluster; everything else is pushed over
# after boot.
{:ok, peer, worker} =
  :peer.start_link(%{
    name: ~c"nous_worker_#{suffix}",
    host: ~c"127.0.0.1",
    longnames: true,
    args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
  })

IO.puts("peer node    : #{worker}")
IO.puts("Node.list()  : #{inspect(Node.list())}")

nodes = [Node.self(), worker]

# Which agent lives where. Declared out here so the `after` block can shut
# every one of them down even if a step above blows up.
placements = [
  {"ingest-01", Node.self(), "invoice-batch-A"},
  {"ingest-02", Node.self(), "invoice-batch-B"},
  {"enrich-01", worker, "invoice-batch-C"},
  {"enrich-02", worker, "invoice-batch-D"}
]

try do
  # ==========================================================================
  # Step 2 - Ship the code and start Nous on the peer
  # ==========================================================================

  IO.puts("\n--- Step 2: Nous running on both nodes ---")

  # The peer booted a bare VM. Hand it our code paths, our :nous config, and
  # then let the standard application supervisor start Nous.AgentRegistry,
  # Nous.AgentDynamicSupervisor and Nous.Persistence.ETS over there.
  :ok = :erpc.call(worker, :code, :add_paths, [:code.get_path()])
  :ok = :erpc.call(worker, Application, :put_all_env, [[nous: Application.get_all_env(:nous)]])
  :ok = :erpc.call(worker, Logger, :configure, [[level: :emergency]])
  {:ok, _apps} = :erpc.call(worker, Application, :ensure_all_started, [:nous], 60_000)

  for node <- nodes do
    vsn = :erpc.call(node, Application, :spec, [:nous, :vsn])
    registry = :erpc.call(node, Process, :whereis, [Nous.AgentRegistry])
    supervisor = :erpc.call(node, Process, :whereis, [Nous.AgentDynamicSupervisor])

    IO.puts("#{node}")
    IO.puts("  nous vsn                    : #{vsn}")
    IO.puts("  Nous.AgentRegistry          : #{inspect(registry)}")
    IO.puts("  Nous.AgentDynamicSupervisor : #{inspect(supervisor)}")
  end

  IO.puts("""

  Note: Nous.AgentRegistry is a plain Registry, which is node-local by design.
  Each node owns its own registry and its own dynamic supervisor, so a session
  id is resolved on the node that hosts it. Pids, however, are cluster-wide:
  everything below calls, monitors and kills remote processes directly.\
  """)

  # ==========================================================================
  # Step 3 - Distribute the tool module
  # ==========================================================================

  IO.puts("\n--- Step 3: Shipping the tool module to the peer ---")

  # Compiled from a string so we have the BEAM binary in hand; a module defined
  # with a bare `defmodule` in a script has no object code to ship.
  [{tool_mod, tool_bin}] =
    Code.compile_string(~S"""
    defmodule DistributedAgentsDemo.Tools do
      @doc "Fingerprint a payload. Pure local computation - no network."
      def node_fingerprint(_ctx, %{"payload" => payload}) do
        digest =
          :sha256
          |> :crypto.hash(payload)
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)

        {:ok, "sha256:#{digest} (computed on #{Node.self()})"}
      end
    end
    """)

  {:module, ^tool_mod} = :erpc.call(worker, :code, :load_binary, [tool_mod, ~c"nofile", tool_bin])
  IO.puts("#{inspect(tool_mod)} loaded on #{worker} (#{byte_size(tool_bin)} bytes of BEAM)")

  fingerprint_tool =
    Nous.Tool.from_function(&DistributedAgentsDemo.Tools.node_fingerprint/2,
      name: "node_fingerprint",
      description: "Fingerprint a payload on the local node",
      category: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{"payload" => %{"type" => "string"}},
        "required" => ["payload"]
      }
    )

  instructions = "You fingerprint payloads using the node_fingerprint tool."

  agent_config = %{
    # A real provider string, but no request is ever issued: this example never
    # calls Nous.run/3 or AgentServer.send_message/2.
    model: "openai:gpt-4o-mini",
    instructions: instructions,
    tools: [fingerprint_tool],
    type: :standard
  }

  # ==========================================================================
  # Step 4 - Start agents on both nodes
  # ==========================================================================

  IO.puts("\n--- Step 4: Agents under supervision on both nodes ---")

  agents =
    for {session_id, agent_node, payload} <- placements do
      {:ok, pid} =
        :erpc.call(agent_node, Nous.AgentDynamicSupervisor, :start_agent, [
          session_id,
          agent_config,
          [persistence: Nous.Persistence.ETS, inactivity_timeout: :infinity]
        ])

      IO.puts("#{String.pad_trailing(session_id, 11)} #{inspect(pid)} on #{node(pid)}")
      %{session_id: session_id, node: agent_node, payload: payload, pid: pid}
    end

  for node <- nodes do
    counts = :erpc.call(node, DynamicSupervisor, :count_children, [Nous.AgentDynamicSupervisor])
    IO.puts("#{node} supervises #{counts.active} agent(s)")
  end

  # ==========================================================================
  # Step 5 - Give every agent some real, offline work
  # ==========================================================================

  IO.puts("\n--- Step 5: Offline work (local tool call, no LLM) ---")

  for %{session_id: session_id, node: agent_node, payload: payload, pid: pid} <- agents do
    # Run the tool on the node that owns the agent.
    {:ok, tool_output} =
      :erpc.call(agent_node, tool_mod, :node_fingerprint, [%{}, %{"payload" => payload}])

    call_id = "call_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    context =
      Nous.Agent.Context.new(
        system_prompt: instructions,
        agent_name: session_id,
        deps: %{payload: payload, owner_node: Atom.to_string(agent_node)}
      )
      |> Nous.Agent.Context.add_messages([
        Nous.Message.user("Fingerprint #{payload}."),
        Nous.Message.assistant("Calling node_fingerprint.",
          tool_calls: [
            %{id: call_id, name: "node_fingerprint", arguments: %{"payload" => payload}}
          ]
        ),
        Nous.Message.tool(call_id, tool_output, name: "node_fingerprint"),
        Nous.Message.assistant(tool_output)
      ])
      |> Nous.Agent.Context.add_usage(%Nous.Usage{tool_calls: 1})
      |> Nous.Agent.Context.increment_iteration()

    # Persist the turn on the agent's own node, then hand it to the live
    # process. Both hops use public API: Nous.Persistence.ETS.save/2 (which
    # is what AgentServer itself writes through) and AgentServer.load_context/2.
    :ok =
      :erpc.call(agent_node, Nous.Persistence.ETS, :save, [
        session_id,
        Nous.Agent.Context.serialize(context)
      ])

    :ok = Nous.AgentServer.load_context(pid, session_id)

    live = Nous.AgentServer.get_context(pid)
    IO.puts("#{String.pad_trailing(session_id, 11)} #{tool_output}")
    IO.puts("            #{length(live.messages)} messages held live by #{inspect(pid)}")
  end

  # ==========================================================================
  # Step 6 - Kill a remote agent
  # ==========================================================================

  IO.puts("\n--- Step 6: Killing a remote agent ---")

  victim = Enum.find(agents, &(&1.session_id == "enrich-01"))
  survivors = Enum.reject(agents, &(&1.session_id == victim.session_id))

  ref = Process.monitor(victim.pid)
  IO.puts("monitoring #{inspect(victim.pid)} on #{node(victim.pid)} from #{Node.self()}")

  Process.exit(victim.pid, :kill)

  receive do
    {:DOWN, ^ref, :process, pid, reason} ->
      IO.puts("DOWN received: #{inspect(pid)} died with #{inspect(reason)}")
  after
    5_000 -> raise "remote agent never went down"
  end

  # The peer's DynamicSupervisor restarts the child; poll its registry until a
  # different pid answers for the same session id.
  wait_for_restart = fn wait_for_restart, attempts ->
    case :erpc.call(victim.node, Nous.AgentRegistry, :lookup, [victim.session_id]) do
      {:ok, pid} when pid != victim.pid ->
        {:ok, pid}

      _ when attempts > 0 ->
        Process.sleep(50)
        wait_for_restart.(wait_for_restart, attempts - 1)

      other ->
        other
    end
  end

  {:ok, restarted_pid} = wait_for_restart.(wait_for_restart, 100)

  IO.puts("restarted    : #{inspect(victim.pid)} -> #{inspect(restarted_pid)} on #{node(restarted_pid)}")
  IO.puts("same session : #{victim.session_id} (Nous.AgentRegistry re-registered it)")

  IO.puts("\nsiblings after the kill:")

  for %{session_id: session_id, pid: pid} <- survivors do
    IO.puts(
      "#{String.pad_trailing(session_id, 11)} #{inspect(pid)} on #{node(pid)} alive?=" <>
        "#{:erpc.call(node(pid), Process, :alive?, [pid])} messages=" <>
        "#{length(Nous.AgentServer.get_context(pid).messages)}"
    )
  end

  for node <- nodes do
    counts = :erpc.call(node, DynamicSupervisor, :count_children, [Nous.AgentDynamicSupervisor])
    IO.puts("#{node} still supervises #{counts.active} agent(s)")
  end

  # ==========================================================================
  # Step 7 - The restarted agent recovered its context
  # ==========================================================================

  IO.puts("\n--- Step 7: Context recovered from persistence ---")

  # AgentServer.init/1 hands off to handle_continue(:load_persisted_context),
  # which reads Nous.Persistence.ETS on the PEER node and runs the blob back
  # through Nous.Agent.Context.deserialize/1.
  recovered = Nous.AgentServer.get_context(restarted_pid)

  IO.puts("recovered from #{node(restarted_pid)} via Nous.Persistence.ETS")
  IO.puts("agent_name   : #{recovered.agent_name}")
  IO.puts("system_prompt: #{recovered.system_prompt}")
  IO.puts("iteration    : #{recovered.iteration}")
  IO.puts("usage        : #{recovered.usage.tool_calls} tool call(s)")
  IO.puts("deps         : #{inspect(recovered.deps)}")
  IO.puts("messages     : #{length(recovered.messages)}")

  for message <- recovered.messages do
    text = message |> Nous.Message.extract_text() |> String.slice(0, 72)
    IO.puts("  [#{message.role}] #{text}")
  end

  # Prove the wire format is stable, not just the in-memory struct.
  blob = Nous.Agent.Context.serialize(recovered)
  {:ok, round_tripped} = Nous.Agent.Context.deserialize(blob)

  IO.puts("\nserialize/1 -> deserialize/1 round trip")
  IO.puts("  version              : #{blob.version}")
  IO.puts("  messages preserved   : #{length(round_tripped.messages) == length(recovered.messages)}")

  IO.puts(
    "  tool result intact   : " <>
      "#{Enum.any?(round_tripped.messages, &(&1.role == :tool and &1.content =~ "sha256:"))}"
  )

  IO.puts("""

  What just happened:
    - two BEAM nodes, one cluster, one shared agent codebase
    - four supervised Nous agents, two per node
    - one agent killed from the OTHER node with Process.exit(pid, :kill)
    - its own node's Nous.AgentDynamicSupervisor restarted it under the same
      session id, and the three siblings never noticed
    - the restarted process came back with its conversation intact, read out
      of Nous.Persistence.ETS via Nous.Agent.Context.deserialize/1

  Nothing here talked to an LLM. Swap the offline turn in Step 5 for a real
  Nous.AgentServer.send_message/2 and the supervision story is unchanged.\
  """)
after
  # ==========================================================================
  # Cleanup
  # ==========================================================================

  IO.puts("\n--- Cleanup ---")

  for {session_id, agent_node, _payload} <- placements do
    :erpc.call(agent_node, Nous.AgentDynamicSupervisor, :stop_agent, [session_id])
  end

  IO.puts("agents stopped")

  :peer.stop(peer)
  IO.puts("peer node stopped, Node.list() = #{inspect(Node.list())}")

  Node.stop()
  IO.puts("distribution stopped")
end

IO.puts("\n=== Demo Complete ===")
