defmodule Nous.Agents.BasicAgent do
  @moduledoc """
  Default agent implementation with standard tool-calling behavior.

  BasicAgent implements the `Nous.Agent.Behaviour` and provides:
  - Standard message building with system prompts
  - Simple tool call detection and execution
  - Text extraction from assistant responses

  This is the default behaviour used when no `behaviour_module` is specified.

  ## Example

      agent = Agent.new("openai:gpt-4",
        instructions: "Be helpful",
        tools: [&search/2]
      )

      # Uses BasicAgent by default
      {:ok, result} = Agent.run(agent, "Search for Elixir tutorials")

  """

  @behaviour Nous.Agent.Behaviour

  alias Nous.{Message, Messages, OutputSchema}
  alias Nous.Agent.Context

  @doc """
  Build messages to send to the LLM.

  Combines system prompt (if any) with conversation messages.
  """
  @impl true
  def build_messages(_agent, ctx) do
    # Start with messages from context
    messages = ctx.messages

    # If system prompt not already in messages, add it
    has_system = Enum.any?(messages, &Message.is_system?/1)

    if not has_system and ctx.system_prompt do
      [Message.system(ctx.system_prompt) | messages]
    else
      messages
    end
  end

  @doc """
  Process a response from the LLM.

  Adds the response to context and updates `needs_response` based on
  whether there are tool calls to process.
  """
  @impl true
  def process_response(_agent, response, ctx) do
    # Add message to context - this also updates needs_response
    Context.add_message(ctx, response)
  end

  @doc """
  Extract the final output from the context.

  Returns the text content of the last assistant message.
  When `output_type` is set, parses and validates the response.
  """
  @impl true
  def extract_output(agent, ctx) do
    case find_output_message(ctx) do
      nil ->
        {:error, :no_output}

      msg ->
        extract_with_output_type(agent, msg)
    end
  end

  defp find_output_message(ctx) do
    case Context.last_message(ctx) do
      %Message{role: :assistant} = msg -> msg
      %Message{role: :tool} -> find_last_assistant_message(ctx.messages)
      _ -> nil
    end
  end

  defp extract_with_output_type(%{output_type: :string}, msg) do
    {:ok, Messages.extract_text(msg)}
  end

  defp extract_with_output_type(%{output_type: output_type, model: model}, msg) do
    text = OutputSchema.extract_response_text(msg, model.provider)
    OutputSchema.parse_and_validate(text, output_type)
  end

  @doc """
  Get tools available for this agent.

  Returns the tools configured on the agent.
  """
  @impl true
  def get_tools(agent) do
    agent.tools
  end

  # Private helpers

  defp find_last_assistant_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :assistant))
  end
end
