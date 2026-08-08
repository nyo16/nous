defmodule Nous.Plugins.HumanInTheLoop do
  # MapSet.member? on the downcased-tool-name lookup uses capture syntax
  # inside Enum.map; same dialyzer opaque-capture false positive.
  @dialyzer :no_opaque

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

  When `:tools` is provided, those tools are additionally tagged with
  `requires_approval: true`. The handler is always called for every tool that
  requires approval — the tagged ones plus any that are inherently gated
  (`Bash`, `FileWrite`, `FileEdit`) or gated by the permission policy. It is
  never a way to *narrow* the gate: an approval-required tool outside `:tools`
  still goes to the handler rather than being auto-approved.

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
      # Case-insensitive matching - Nous.Permissions normalises tool names to
      # downcase, and a mismatch here meant a tool registered as "Send_Email"
      # bypassed approval if the operator wrote "send_email" (and vice versa).
      lookup = downcase_set(tool_names)

      tagged_tools = Enum.map(tools, &tag_if_gated(&1, lookup))

      {ctx, tagged_tools}
    end
  end

  # The handler is invoked ONLY for tools already flagged
  # `requires_approval: true` — `before_request/3` above does that flagging for
  # the configured `:tools` list. Filtering the handler by the same list was a
  # fail-open bug: any OTHER approval-gated tool (Bash, FileWrite, FileEdit)
  # took the `else` branch and was silently auto-approved, so installing this
  # plugin made the agent LESS safe than leaving it out (no handler at all is
  # default-deny). Pass the handler straight through.
  defp build_handler(handler, _tool_names), do: handler

  defp tag_if_gated(tool, lookup) do
    if matches?(lookup, tool.name), do: %{tool | requires_approval: true}, else: tool
  end

  defp downcase_set(names) when is_list(names) do
    names |> Enum.map(fn n -> n |> to_string() |> String.downcase() end) |> MapSet.new()
  end

  defp matches?(lookup, name) when is_binary(name),
    do: MapSet.member?(lookup, String.downcase(name))

  defp matches?(_lookup, _name), do: false
end
