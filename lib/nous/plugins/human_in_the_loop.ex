defmodule Nous.Plugins.HumanInTheLoop do
  @moduledoc """
  Plugin for human-in-the-loop approval of tool calls.

  Sets up an approval handler that intercepts tool calls for specified tools.
  The handler is called before each tool execution for tools that have
  `requires_approval: true`, or for tools whose names match the configured list.

  ## Configuration

  Store the HITL config in `deps` under the `:hitl_config` key:

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.HumanInTheLoop],
        tools: [&MyTools.send_email/2, &MyTools.search/2]
      )

      {:ok, result} = Agent.run(agent, "Send an email to bob",
        deps: %{
          hitl_config: %{
            tools: ["send_email"],
            handler: fn tool_call ->
              IO.inspect(tool_call, label: "Approve?")
              :approve
            end
          }
        }
      )

  When `:tools` is provided, those tools are automatically tagged with
  `requires_approval: true` and the handler is only called for matching tools.
  When `:tools` is omitted or empty, the handler is called for all tools
  that already have `requires_approval: true`.

  ## Handler Responses

    * `:approve` - Proceed with execution
    * `:reject` - Skip execution, return rejection message
    * `{:edit, new_args}` - Proceed with modified arguments

  """

  @behaviour Nous.Plugin

  @impl true
  def init(_agent, ctx) do
    config = get_in(ctx.deps, [:hitl_config])

    case config do
      %{handler: handler} when is_function(handler) ->
        tool_names = Map.get(config, :tools, [])
        wrapped = build_handler(handler, tool_names)
        %{ctx | approval_handler: wrapped}

      _ ->
        ctx
    end
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    tool_names = get_in(ctx.deps, [:hitl_config, :tools]) || []

    if tool_names == [] do
      {ctx, tools}
    else
      tagged_tools =
        Enum.map(tools, fn tool ->
          if tool.name in tool_names do
            %{tool | requires_approval: true}
          else
            tool
          end
        end)

      {ctx, tagged_tools}
    end
  end

  defp build_handler(handler, []) do
    handler
  end

  defp build_handler(handler, tool_names) do
    fn tool_call ->
      if tool_call.name in tool_names do
        handler.(tool_call)
      else
        :approve
      end
    end
  end
end
