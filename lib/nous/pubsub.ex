defmodule Nous.PubSub do
  require Logger

  @moduledoc """
  Thin PubSub abstraction for Nous.

  Wraps Phoenix.PubSub with graceful fallback when it's not available.
  Provides application-level configuration so users don't need to pass
  `pubsub: MyApp.PubSub` to every AgentServer.

  ## Configuration

      # In config/config.exs
      config :nous, pubsub: MyApp.PubSub

  ## Usage

      # Subscribe (no-op if PubSub unavailable)
      Nous.PubSub.subscribe(MyApp.PubSub, "agent:session_123")

      # Broadcast (no-op if PubSub unavailable)
      Nous.PubSub.broadcast(MyApp.PubSub, "agent:session_123", {:agent_delta, "Hello"})

      # Use configured PubSub
      pubsub = Nous.PubSub.configured_pubsub()

  """

  @doc """
  Returns the application-configured PubSub module.

  Reads from `Application.get_env(:nous, :pubsub)`.
  Returns `nil` if not configured.
  """
  @spec configured_pubsub() :: module() | nil
  def configured_pubsub do
    Application.get_env(:nous, :pubsub)
  end

  @doc """
  Checks if PubSub is available (Phoenix.PubSub loaded and a module configured).
  """
  @spec available?() :: boolean()
  def available? do
    available?(configured_pubsub())
  end

  @doc """
  Checks if PubSub is available for the given module.

  Returns `true` if Phoenix.PubSub is loaded and `pubsub` is not nil.
  """
  @spec available?(module() | nil) :: boolean()
  def available?(nil), do: false

  def available?(_pubsub) do
    Code.ensure_loaded?(Phoenix.PubSub)
  end

  @doc """
  Subscribe the calling process to a topic.

  No-op if PubSub is unavailable.
  """
  @spec subscribe(module() | nil, String.t()) :: :ok | {:error, term()}
  def subscribe(pubsub, topic)

  def subscribe(nil, _topic), do: :ok

  def subscribe(pubsub, topic) do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      try do
        apply(Phoenix.PubSub, :subscribe, [pubsub, topic])
      catch
        :error, %ArgumentError{} ->
          :ok

        :error, reason ->
          Logger.debug("PubSub subscribe failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Broadcast a message on a topic.

  No-op if PubSub is unavailable.
  """
  @spec broadcast(module() | nil, String.t() | nil, term()) :: :ok | {:error, term()}
  def broadcast(pubsub, topic, message)

  def broadcast(nil, _topic, _message), do: :ok
  def broadcast(_pubsub, nil, _message), do: :ok

  def broadcast(pubsub, topic, message) do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      try do
        apply(Phoenix.PubSub, :broadcast, [pubsub, topic, message])
      catch
        :error, %ArgumentError{} ->
          :ok

        :error, reason ->
          Logger.debug("PubSub broadcast failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # Topic builders

  @doc """
  Build an agent topic for the given session ID.

      iex> Nous.PubSub.agent_topic("abc123")
      "nous:agent:abc123"

  """
  @spec agent_topic(String.t()) :: String.t()
  def agent_topic(session_id), do: "nous:agent:#{session_id}"

  @doc """
  Build a research topic for the given session ID.

      iex> Nous.PubSub.research_topic("abc123")
      "nous:research:abc123"

  """
  @spec research_topic(String.t()) :: String.t()
  def research_topic(session_id), do: "nous:research:#{session_id}"

  @doc """
  Build an approval topic for the given session ID.

      iex> Nous.PubSub.approval_topic("abc123")
      "nous:approval:abc123"

  """
  @spec approval_topic(String.t()) :: String.t()
  def approval_topic(session_id), do: "nous:approval:#{session_id}"
end
