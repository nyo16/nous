defmodule Nous.PubSub.Approval do
  @moduledoc """
  Async HITL approval via PubSub.

  Provides a handler function compatible with `Nous.Plugins.HumanInTheLoop`
  that broadcasts approval requests and waits for responses via PubSub.
  This enables LiveView or other external processes to approve/reject
  tool calls asynchronously.

  ## Usage

      # In your agent setup:
      deps = %{
        hitl_config: %{
          tools: ["send_email"],
          handler: Nous.PubSub.Approval.handler(
            pubsub: MyApp.PubSub,
            session_id: session_id,
            timeout: :timer.minutes(5)
          )
        }
      }

      # In your LiveView:
      def handle_info({:approval_required, approval}, socket) do
        {:noreply, assign(socket, pending_approval: approval)}
      end

      def handle_event("approve", _params, socket) do
        approval = socket.assigns.pending_approval
        Nous.PubSub.Approval.respond(
          MyApp.PubSub, approval.session_id, approval.tool_call_id, :approve
        )
        {:noreply, socket}
      end

  """

  @default_timeout :timer.minutes(5)

  @doc """
  Build an approval handler function for use with `Nous.Plugins.HumanInTheLoop`.

  The returned function:
  1. Broadcasts `{:approval_required, info}` on the agent topic
  2. Subscribes to the approval topic and blocks via `receive`
  3. Returns the decision when received, or `:reject` on timeout

  ## Options

    * `:pubsub` - PubSub module (falls back to `Nous.PubSub.configured_pubsub/0`)
    * `:session_id` - Session ID for topic routing (required)
    * `:timeout` - How long to wait for a response (default: 5 minutes)

  """
  @spec handler(keyword()) :: (map() -> :approve | :reject | {:edit, map()})
  def handler(opts) do
    pubsub = Keyword.get(opts, :pubsub) || Nous.PubSub.configured_pubsub()
    session_id = Keyword.fetch!(opts, :session_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    fn tool_call ->
      wait_for_approval(pubsub, session_id, tool_call, timeout)
    end
  end

  @doc """
  Send an approval response for a pending tool call.

  Broadcasts `{:approval_response, tool_call_id, decision}` on the
  approval topic for the given session.

  ## Parameters

    * `pubsub` - PubSub module
    * `session_id` - Session ID
    * `tool_call_id` - The tool call ID to respond to
    * `decision` - `:approve`, `:reject`, or `{:edit, new_args}`

  """
  @spec respond(module(), String.t(), String.t(), :approve | :reject | {:edit, map()}) ::
          :ok | {:error, term()}
  def respond(pubsub, session_id, tool_call_id, decision) do
    topic = Nous.PubSub.approval_topic(session_id)
    Nous.PubSub.broadcast(pubsub, topic, {:approval_response, tool_call_id, decision})
  end

  # Private

  defp wait_for_approval(pubsub, session_id, tool_call, timeout) do
    agent_topic = Nous.PubSub.agent_topic(session_id)
    approval_topic = Nous.PubSub.approval_topic(session_id)

    tool_call_id = Map.get(tool_call, :id) || Map.get(tool_call, "id")

    # Subscribe to approval responses
    Nous.PubSub.subscribe(pubsub, approval_topic)

    # Broadcast that approval is needed
    Nous.PubSub.broadcast(pubsub, agent_topic, {
      :approval_required,
      %{
        tool_call_id: tool_call_id,
        name: Map.get(tool_call, :name) || Map.get(tool_call, "name"),
        arguments: Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments"),
        session_id: session_id
      }
    })

    # Block waiting for response
    receive do
      {:approval_response, ^tool_call_id, decision} ->
        decision
    after
      timeout ->
        :reject
    end
  end
end
