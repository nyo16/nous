defmodule Nous.Plugin do
  @moduledoc """
  Behaviour for composable agent extensions.

  Plugins allow you to extend agent capabilities without modifying the core agent
  or creating monolithic behaviour modules. Multiple plugins can be composed together.

  ## Example

      defmodule MyApp.Plugins.Logging do
        @behaviour Nous.Plugin

        @impl true
        def init(_agent, ctx) do
          ctx
        end

        @impl true
        def before_request(_agent, ctx, _tools) do
          IO.puts("Making LLM request with \#{length(ctx.messages)} messages")
          {ctx, []}
        end

        @impl true
        def after_response(_agent, response, ctx) do
          IO.puts("Got response: \#{inspect(response.content)}")
          ctx
        end
      end

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [MyApp.Plugins.Logging, Nous.Plugins.TodoTracking]
      )

  ## Callback Execution Order

  Plugins are executed in list order. The context flows through each plugin
  sequentially for all hooks:

  1. `init/2` — once at run start (see `c:init/2` for continued contexts)
  2. `hooks/2` — once per run, after `init/2` (and on every
     `Nous.AgentRunner.run_with_context/3`); merged after `agent.hooks`
  3. `system_prompt/2` — once, fragments joined into system message
  4. `tools/2` — once per iteration, tools collected
  5. `before_request/3` — before each LLM call
  6. `after_response/3` — after each LLM response
  7. `after_run/3` — once after the entire run completes (post-loop)

  ## Built-in Plugins

  - `Nous.Plugins.TodoTracking` - Automatic todo/task management
  - `Nous.Plugins.HumanInTheLoop` - Human approval for tool calls
  - `Nous.Plugins.Summarization` - Context window management
  """

  alias Nous.Agent.Context

  @doc """
  Initialize the plugin when the agent run starts.

  Use this to set up initial state in `ctx.deps`, register callbacks, etc.

  Called once at the start of every `Nous.AgentRunner.run/3` and
  `Nous.AgentRunner.run_stream/3`, including one given a previous run's
  `:context`. `Nous.AgentRunner.run_with_context/3` (which
  `Nous.run(agent, messages: [...])` and `Nous.AgentServer` inbox runs use)
  calls it only for a context that has not been initialised yet: a hand-built
  or restored context is initialised once, a previous run's `result.context`
  is continued without re-running `init/2`.
  """
  @callback init(agent :: Nous.Agent.t(), ctx :: Context.t()) :: Context.t()

  @doc """
  Contribute additional tools for this agent run.

  Return a list of `Nous.Tool` structs to add to the agent's tool set.
  Called once per iteration before the LLM request.
  """
  @callback tools(agent :: Nous.Agent.t(), ctx :: Context.t()) :: [Nous.Tool.t()]

  @doc """
  Contribute system prompt fragments.

  Return a string to append to the system prompt, or nil for no contribution.
  Fragments from all plugins are joined with newlines.
  """
  @callback system_prompt(agent :: Nous.Agent.t(), ctx :: Context.t()) :: String.t() | nil

  @doc """
  Pre-process before each LLM call.

  Receives the current context and tools list. Return the updated context
  and the updated tools list.
  """
  @callback before_request(agent :: Nous.Agent.t(), ctx :: Context.t(), tools :: [Nous.Tool.t()]) ::
              {Context.t(), [Nous.Tool.t()]}

  @doc """
  Post-process after each LLM response.

  Receives the LLM response message and current context.
  Return the updated context.
  """
  @callback after_response(
              agent :: Nous.Agent.t(),
              response :: Nous.Message.t(),
              ctx :: Context.t()
            ) ::
              Context.t()

  @doc """
  Post-process after the entire agent run completes.

  Receives the agent, the final result map, and the final context.
  Return the updated context. Use this for end-of-run housekeeping
  like auto-updating memory.
  """
  @callback after_run(agent :: Nous.Agent.t(), result :: map(), ctx :: Context.t()) :: Context.t()

  @doc """
  Contribute `Nous.Hook`s for this agent run.

  Called once per run, after every plugin's `init/2`, so `ctx` already holds
  the final approval handler and deps. The run's hook registry is rebuilt from
  `agent.hooks ++` the hooks of every plugin (in list order) on each run, so
  hooks never accumulate across `Nous.AgentServer` turns. Order within a
  priority is registration order: agent hooks first, then plugin hooks.
  """
  @callback hooks(agent :: Nous.Agent.t(), ctx :: Context.t()) :: [Nous.Hook.t()]

  @optional_callbacks [
    init: 2,
    tools: 2,
    system_prompt: 2,
    hooks: 2,
    before_request: 3,
    after_response: 3,
    after_run: 3
  ]

  # Plugin execution helpers

  @doc """
  Run `init/2` across all plugins, threading context through each.
  """
  @spec run_init([module()], Nous.Agent.t(), Context.t()) :: Context.t()
  def run_init(plugins, agent, ctx) do
    Enum.reduce(plugins, ctx, fn plugin, acc_ctx ->
      if exports?(plugin, :init, 2) do
        plugin.init(agent, acc_ctx)
      else
        acc_ctx
      end
    end)
  end

  @doc """
  Collect tools from all plugins.
  """
  @spec collect_tools([module()], Nous.Agent.t(), Context.t()) :: [Nous.Tool.t()]
  def collect_tools(plugins, agent, ctx) do
    Enum.flat_map(plugins, fn plugin ->
      if exports?(plugin, :tools, 2) do
        plugin.tools(agent, ctx)
      else
        []
      end
    end)
  end

  @doc """
  Collect hooks from all plugins, in plugin list order.
  """
  @spec collect_hooks([module()], Nous.Agent.t(), Context.t()) :: [Nous.Hook.t()]
  def collect_hooks(plugins, agent, ctx) do
    Enum.flat_map(plugins, fn plugin ->
      if exports?(plugin, :hooks, 2) do
        plugin.hooks(agent, ctx)
      else
        []
      end
    end)
  end

  @doc """
  Collect system prompt fragments from all plugins.
  """
  @spec collect_system_prompts([module()], Nous.Agent.t(), Context.t()) :: String.t() | nil
  def collect_system_prompts(plugins, agent, ctx) do
    fragments =
      plugins
      |> Enum.map(fn plugin ->
        if exports?(plugin, :system_prompt, 2) do
          plugin.system_prompt(agent, ctx)
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case fragments do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @doc """
  Run `before_request/3` across all plugins, threading context and tools.

  Each plugin receives the current tools and returns the updated tools list.
  """
  @spec run_before_request([module()], Nous.Agent.t(), Context.t(), [Nous.Tool.t()]) ::
          {Context.t(), [Nous.Tool.t()]}
  def run_before_request(plugins, agent, ctx, tools) do
    Enum.reduce(plugins, {ctx, tools}, fn plugin, {acc_ctx, acc_tools} ->
      if exports?(plugin, :before_request, 3) do
        plugin.before_request(agent, acc_ctx, acc_tools)
      else
        {acc_ctx, acc_tools}
      end
    end)
  end

  @doc """
  Run `after_response/3` across all plugins, threading context.
  """
  @spec run_after_response([module()], Nous.Agent.t(), Nous.Message.t(), Context.t()) ::
          Context.t()
  def run_after_response(plugins, agent, response, ctx) do
    Enum.reduce(plugins, ctx, fn plugin, acc_ctx ->
      if exports?(plugin, :after_response, 3) do
        plugin.after_response(agent, response, acc_ctx)
      else
        acc_ctx
      end
    end)
  end

  @doc """
  Run `after_run/3` across all plugins, threading context.
  """
  @spec run_after_run([module()], Nous.Agent.t(), map(), Context.t()) :: Context.t()
  def run_after_run(plugins, agent, result, ctx) do
    Enum.reduce(plugins, ctx, fn plugin, acc_ctx ->
      if exports?(plugin, :after_run, 3) do
        plugin.after_run(agent, result, acc_ctx)
      else
        acc_ctx
      end
    end)
  end

  # Ensure module is loaded before checking exports
  defp exports?(module, function, arity) do
    Code.ensure_loaded(module)
    function_exported?(module, function, arity)
  end
end
