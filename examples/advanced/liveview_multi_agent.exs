# LiveView Multi-Agent Dashboard — Reference Example
#
# A dashboard that spawns multiple agents with different roles, tracks
# their progress in real time, and aggregates results — all via PubSub.
#
# This is a REFERENCE implementation — integrate into your Phoenix app.
# It is not runnable as a standalone script (LiveView requires Phoenix).
#
# Features:
#   - Spawn multiple agents with distinct roles
#   - Real-time progress updates via PubSub
#   - Per-agent status tracking (pending / running / completed / failed)
#   - Aggregated results display
#
# Prerequisites:
#   - Phoenix ~> 1.7 with LiveView ~> 0.20
#   - Nous added to your deps
#   - PubSub configured:  config :nous, pubsub: MyApp.PubSub
#
# See also:
#   - examples/advanced/liveview_chat.exs       (single-agent chat)
#   - examples/13_sub_agents.exs                (sub-agent patterns)
#   - docs/guides/liveview-integration.md       (full guide)

defmodule MyAppWeb.MultiAgentDashboardLive do
  @moduledoc """
  LiveView dashboard for running multiple Nous agents in parallel
  and displaying their status and results in real time.
  """
  use MyAppWeb, :live_view

  # ------------------------------------------------------------------
  # Agent role definitions
  # ------------------------------------------------------------------

  # Each role has a name, model, and instructions.
  # Customize these for your use case (research, analysis, etc.).
  @agent_roles [
    %{
      id: "researcher",
      label: "Researcher",
      model: "lmstudio:qwen3",
      instructions: "You are a research assistant. Find key facts and summarize them."
    },
    %{
      id: "analyst",
      label: "Analyst",
      model: "lmstudio:qwen3",
      instructions: "You are a data analyst. Identify patterns and insights."
    },
    %{
      id: "writer",
      label: "Writer",
      model: "lmstudio:qwen3",
      instructions: "You are a technical writer. Produce clear, concise summaries."
    }
  ]

  # ------------------------------------------------------------------
  # Mount
  # ------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    run_id = generate_id()

    # Subscribe to a dashboard-wide topic for aggregated events
    if connected?(socket) do
      Nous.PubSub.subscribe(
        Nous.PubSub.configured_pubsub(),
        dashboard_topic(run_id)
      )
    end

    agents =
      for role <- @agent_roles, into: %{} do
        {role.id,
         %{
           id: role.id,
           label: role.label,
           status: :pending,
           output: nil,
           error: nil,
           streaming_text: ""
         }}
      end

    {:ok,
     assign(socket,
       run_id: run_id,
       agents: agents,
       query: "",
       running: false,
       all_done: false,
       form: to_form(%{"query" => ""})
     )}
  end

  # ------------------------------------------------------------------
  # User submits a query to all agents
  # ------------------------------------------------------------------

  @impl true
  def handle_event("run_all", %{"query" => query}, socket) when byte_size(query) > 0 do
    if socket.assigns.running do
      {:noreply, socket}
    else
      run_id = socket.assigns.run_id
      pubsub = Nous.PubSub.configured_pubsub()

      # Reset agent states
      agents =
        for {id, agent} <- socket.assigns.agents, into: %{} do
          {id, %{agent | status: :running, output: nil, error: nil, streaming_text: ""}}
        end

      # Spawn one Task per agent role
      for role <- @agent_roles do
        Task.start(fn ->
          agent = Nous.new(role.model, instructions: role.instructions)

          # Broadcast streaming deltas so the LiveView can show per-agent progress
          try do
            {:ok, result} =
              Nous.run(agent, query,
                callbacks: %{
                  on_llm_new_delta: fn _event, delta ->
                    Nous.PubSub.broadcast(
                      pubsub,
                      dashboard_topic(run_id),
                      {:agent_delta, role.id, delta}
                    )
                  end
                }
              )

            Nous.PubSub.broadcast(
              pubsub,
              dashboard_topic(run_id),
              {:agent_done, role.id, result.output}
            )
          rescue
            e ->
              Nous.PubSub.broadcast(
                pubsub,
                dashboard_topic(run_id),
                {:agent_failed, role.id, Exception.message(e)}
              )
          end
        end)
      end

      {:noreply,
       socket
       |> assign(agents: agents, query: query, running: true, all_done: false)
       |> assign(form: to_form(%{"query" => query}))}
    end
  end

  def handle_event("run_all", _params, socket), do: {:noreply, socket}

  # ------------------------------------------------------------------
  # PubSub callbacks
  # ------------------------------------------------------------------

  @impl true
  # Streaming text delta from a specific agent
  def handle_info({:agent_delta, agent_id, delta}, socket) do
    agents =
      update_agent(socket.assigns.agents, agent_id, fn agent ->
        %{agent | streaming_text: agent.streaming_text <> delta}
      end)

    {:noreply, assign(socket, agents: agents)}
  end

  # Agent completed successfully
  def handle_info({:agent_done, agent_id, output}, socket) do
    agents =
      update_agent(socket.assigns.agents, agent_id, fn agent ->
        %{agent | status: :completed, output: output, streaming_text: ""}
      end)

    all_done = Enum.all?(agents, fn {_id, a} -> a.status in [:completed, :failed] end)

    {:noreply, assign(socket, agents: agents, running: !all_done, all_done: all_done)}
  end

  # Agent failed
  def handle_info({:agent_failed, agent_id, error}, socket) do
    agents =
      update_agent(socket.assigns.agents, agent_id, fn agent ->
        %{agent | status: :failed, error: error, streaming_text: ""}
      end)

    all_done = Enum.all?(agents, fn {_id, a} -> a.status in [:completed, :failed] end)

    {:noreply, assign(socket, agents: agents, running: !all_done, all_done: all_done)}
  end

  # Catch-all
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ------------------------------------------------------------------
  # Template
  # ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6">
      <h1 class="text-2xl font-bold mb-4">Multi-Agent Dashboard</h1>

      <%!-- Query input --%>
      <.form for={@form} phx-submit="run_all" class="flex gap-2 mb-6">
        <input
          type="text"
          name="query"
          value={@form[:query].value}
          placeholder="Enter a query for all agents..."
          disabled={@running}
          class="flex-1 p-2 border rounded"
        />
        <button type="submit" disabled={@running} class="px-4 py-2 bg-blue-500 text-white rounded disabled:opacity-50">
          <%= if @running, do: "Running...", else: "Run All Agents" %>
        </button>
      </.form>

      <%!-- Agent cards --%>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <%= for {_id, agent} <- @agents do %>
          <div class="border rounded-lg p-4 flex flex-col">
            <div class="flex justify-between items-center mb-2">
              <h2 class="font-semibold"><%= agent.label %></h2>
              <.status_badge status={agent.status} />
            </div>

            <div class="flex-1 text-sm overflow-y-auto max-h-64">
              <%= cond do %>
                <% agent.status == :running and agent.streaming_text != "" -> %>
                  <div class="whitespace-pre-wrap text-gray-700">
                    <%= agent.streaming_text %><span class="animate-pulse">|</span>
                  </div>
                <% agent.status == :running -> %>
                  <div class="text-gray-400 animate-pulse">Thinking...</div>
                <% agent.status == :completed -> %>
                  <div class="whitespace-pre-wrap"><%= agent.output %></div>
                <% agent.status == :failed -> %>
                  <div class="text-red-600"><%= agent.error %></div>
                <% true -> %>
                  <div class="text-gray-400">Waiting for query...</div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Summary when all done --%>
      <%= if @all_done do %>
        <div class="mt-6 p-4 border rounded bg-green-50">
          <h2 class="font-bold mb-2">All agents finished</h2>
          <p class="text-sm text-gray-600">
            <%= Enum.count(@agents, fn {_, a} -> a.status == :completed end) %> completed,
            <%= Enum.count(@agents, fn {_, a} -> a.status == :failed end) %> failed
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Components
  # ------------------------------------------------------------------

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "px-2 py-0.5 rounded text-xs font-medium",
      @status == :pending   && "bg-gray-200 text-gray-600",
      @status == :running   && "bg-blue-200 text-blue-700",
      @status == :completed && "bg-green-200 text-green-700",
      @status == :failed    && "bg-red-200 text-red-700"
    ]}>
      <%= @status %>
    </span>
    """
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp update_agent(agents, agent_id, fun) do
    Map.update!(agents, agent_id, fun)
  end

  defp dashboard_topic(run_id), do: "nous:dashboard:#{run_id}"

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
