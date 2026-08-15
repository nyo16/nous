defmodule Nous.CodeModeTest do
  # Sync: several tests configure `:nous, :code_runtime` / `:code_mode`, which
  # every agent run in the VM reads.
  use ExUnit.Case, async: false

  alias Nous.CodeMode
  alias Nous.CodeRuntime.Binding
  alias Nous.{Agent, AgentRunner, Permissions, RunContext, Tool, Usage}

  doctest Nous.CodeMode

  # A provider that stands in for the substrate. With `call: name` it does what
  # a real program would: reaches Elixir through the bindings it was handed.
  defmodule StubRuntime do
    @moduledoc false
    @behaviour Nous.CodeRuntime

    alias Nous.CodeRuntime.Result

    @impl true
    def language(config), do: Keyword.get(config, :language, "javascript")

    @impl true
    def isolation(_config), do: "none — test double"

    @impl true
    def start_run(request, config) do
      ref = make_ref()
      send(request.owner, {:code_run, ref, run(request, Keyword.get(config, :call))})
      {:ok, ref}
    end

    @impl true
    def cancel(_ref, _reason), do: :ok

    defp run(_request, nil), do: Result.ok(nil)

    defp run(request, name) do
      [binding] = request.bindings

      case binding.functions[name].(%{"from" => "the program"}) do
        {:ok, value} -> Result.ok(value, ["called #{name}"])
        {:error, error} -> Result.failed(:exception, inspect(error), ["called #{name}"])
      end
    end
  end

  # Emits one tool call for a native tool, then a final answer.
  defmodule ToolCallDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, message([{:text, "final answer"}])}
      else
        {:ok, message([{:tool_call, %{id: "c1", name: "guarded", arguments: %{}}}])}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0

    defp message(parts) do
      Nous.Message.from_legacy(%{
        parts: parts,
        usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      })
    end
  end

  # Two calls in one response, so the parallel pre-stage runs.
  defmodule ParallelToolCallDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, message([{:text, "final answer"}])}
      else
        {:ok,
         message([
           {:tool_call, %{id: "c1", name: "guarded", arguments: %{}}},
           {:tool_call, %{id: "c2", name: "guarded", arguments: %{}}}
         ])}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0

    defp message(parts) do
      Nous.Message.from_legacy(%{
        parts: parts,
        usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      })
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:nous, :code_runtime)
      Application.delete_env(:nous, :code_mode)
    end)

    :ok
  end

  defp tool(name, fun \\ nil) do
    fun = fun || fn _ctx, _args -> {:ok, "#{name} ran"} end

    %Tool{
      name: name,
      description: "The #{name} tool.",
      function: fun,
      takes_ctx: true,
      timeout: nil,
      parameters: %{"type" => "object", "properties" => %{}, "required" => []}
    }
  end

  defp configure_runtime(config \\ []) do
    Application.put_env(:nous, :code_runtime, {StubRuntime, config})
  end

  defp names(tools), do: Enum.map(tools, & &1.name)

  describe "mode coercion" do
    test "accepts the three modes as atoms and as strings" do
      assert CodeMode.new(:native) == :native
      assert CodeMode.new(:code) == :code
      assert CodeMode.new(:both) == :both
      assert CodeMode.new("native") == :native
      assert CodeMode.new("code") == :code
      assert CodeMode.new("both") == :both
    end

    test "refuses anything else without minting an atom for it" do
      assert_raise ArgumentError, ~r/invalid code mode/, fn ->
        CodeMode.new("wide_open_code_mode")
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom("wide_open_code_mode") end

      assert_raise ArgumentError, fn -> CodeMode.new(:wide_open) end
      assert_raise ArgumentError, fn -> CodeMode.new(nil) end
    end

    test "an agent normalizes its mode at construction" do
      assert Agent.new("openai:test-model", code_mode: "code").code_mode == :code
      assert Agent.new("openai:test-model").code_mode == nil

      assert_raise ArgumentError, fn ->
        Agent.new("openai:test-model", code_mode: :nonsense)
      end
    end
  end

  describe "mode resolution" do
    test "the agent wins, then config, then the default" do
      assert CodeMode.resolve(%{code_mode: :code}) == :code

      Application.put_env(:nous, :code_mode, "native")
      assert CodeMode.resolve(%{code_mode: :code}) == :code
      assert CodeMode.resolve(%{code_mode: nil}) == :native
      assert CodeMode.resolve(nil) == :native

      Application.delete_env(:nous, :code_mode)
      assert CodeMode.resolve(nil) == :both
    end

    test "a bad configured mode raises where it is read, naming the value" do
      Application.put_env(:nous, :code_mode, "sideways")

      assert_raise ArgumentError, ~r/"sideways"/, fn -> CodeMode.default_mode() end
    end
  end

  describe "runtime configuration" do
    test "reports an actionable error when nothing is configured" do
      assert {:error, message} = CodeMode.runtime()
      assert message =~ "config :nous, :code_runtime"
      refute CodeMode.runtime_configured?()
    end

    test "accepts {module, config} and a bare module" do
      configure_runtime(language: "python")
      assert CodeMode.runtime() == {:ok, {StubRuntime, [language: "python"]}}
      assert CodeMode.language() == :python

      Application.put_env(:nous, :code_runtime, StubRuntime)
      assert CodeMode.runtime() == {:ok, {StubRuntime, []}}
      assert CodeMode.language() == :javascript
    end

    test "rejects a module that does not implement the behaviour" do
      Application.put_env(:nous, :code_runtime, Enum)

      assert {:error, message} = CodeMode.runtime()
      assert message =~ "does not implement Nous.CodeRuntime"
      refute CodeMode.runtime_configured?()
    end

    test "a provider naming an unrenderable language falls back rather than failing" do
      configure_runtime(language: "malbolge")

      assert CodeMode.language() == :javascript
    end
  end

  describe "the visible tool set" do
    setup do
      configure_runtime()
      tools = [tool("alpha"), tool("beta")]
      {:ok, tools: tools}
    end

    test ":native exposes the tools and no run_code", %{tools: tools} do
      assert names(CodeMode.visible_tools(:native, tools, tools)) == ["alpha", "beta"]
    end

    test ":code exposes run_code and nothing else", %{tools: tools} do
      assert names(CodeMode.visible_tools(:code, tools, tools)) == ["run_code"]
    end

    test ":both exposes both", %{tools: tools} do
      assert names(CodeMode.visible_tools(:both, tools, tools)) == ["alpha", "beta", "run_code"]
    end

    test ":both degrades to :native with no runtime configured", %{tools: tools} do
      Application.delete_env(:nous, :code_runtime)

      assert names(CodeMode.visible_tools(:both, tools, tools)) == ["alpha", "beta"]
    end

    test ":code keeps run_code even with no runtime, because the operator asked for it", %{
      tools: tools
    } do
      Application.delete_env(:nous, :code_runtime)

      assert names(CodeMode.visible_tools(:code, tools, tools)) == ["run_code"]
    end

    test "run_code carries the SDK for the granted tools only", %{tools: tools} do
      [run_code] = CodeMode.visible_tools(:code, tools, [hd(tools)])

      assert run_code.description =~ ~s|"alpha"(args:|
      refute run_code.description =~ ~s|"beta"(args:|
    end

    test "run_code never retries: a program's side effects have already happened", %{
      tools: tools
    } do
      [run_code] = CodeMode.visible_tools(:code, tools, tools)

      assert run_code.retries == 0
    end
  end

  describe "run_code sits outside the restriction layers" do
    test "a policy that denies every tool still leaves run_code reachable" do
      configure_runtime()
      tools = [tool("alpha"), tool("beta")]
      # :strict exposes only what is explicitly allowed; nothing is.
      policy = Permissions.strict_policy()

      granted = Permissions.filter_tools(policy, tools)
      assert granted == []

      visible = CodeMode.visible_tools(:code, tools, granted, policy: policy)
      assert names(visible) == ["run_code"]
    end

    test "and its bindings are all error stubs naming the tool" do
      tools = [tool("alpha"), tool("beta")]
      policy = Permissions.strict_policy()

      [%Binding{} = binding] = CodeMode.bindings(tools, policy, RunContext.new(%{}))

      assert binding.global == "tools"
      assert Map.keys(binding.functions) |> Enum.sort() == ["alpha", "beta"]

      for name <- ["alpha", "beta"] do
        assert {:error, %{"tool" => ^name, "message" => message}} =
                 binding.functions[name].(%{})

        assert message =~ "denied by the permission policy"
      end
    end

    test "the run_code tool still runs the whole pipeline: a hook sees the program text" do
      configure_runtime()
      test_pid = self()

      hook =
        Nous.Hook.new(:pre_tool_use,
          handler: fn _event, payload ->
            send(test_pid, {:hook_saw, payload.tool_name, payload.arguments})
            {:deny, "not this program"}
          end,
          name: "program-inspector"
        )

      Nous.ModelDispatcher.put_dispatcher(__MODULE__.RunCodeDispatcher)

      agent =
        Agent.new("openai:test-model",
          tools: [tool("alpha")],
          code_mode: :code,
          hooks: [hook]
        )

      assert {:ok, result} = AgentRunner.run(agent, "go")

      assert_receive {:hook_saw, "run_code", arguments}
      assert arguments["code"] =~ "tools[\"alpha\"]"
      assert tool_message(result) =~ "denied by hook"
    end

    test "end to end: the model writes a program, the program calls a tool, the answer returns" do
      test_pid = self()

      configure_runtime(call: "alpha")
      Nous.ModelDispatcher.put_dispatcher(__MODULE__.RunCodeDispatcher)

      alpha =
        tool("alpha", fn ctx, args ->
          send(test_pid, {:alpha_ran, args, ctx.approval_gated?})
          {:ok, "alpha saw #{args["from"]}"}
        end)

      agent = Agent.new("openai:test-model", tools: [alpha], code_mode: :code)

      assert {:ok, result} = AgentRunner.run(agent, "go")

      # The program reached the tool through its binding, with the caller's
      # context and the runner's approval gate already applied.
      assert_receive {:alpha_ran, %{"from" => "the program"}, true}

      message = tool_message(result)
      assert message =~ "alpha saw the program"
      assert message =~ "called alpha"
    end

    test "a denied tool called from inside a program fails comprehensibly" do
      test_pid = self()

      configure_runtime(call: "alpha")
      Nous.ModelDispatcher.put_dispatcher(__MODULE__.RunCodeDispatcher)

      alpha =
        tool("alpha", fn _ctx, _args ->
          send(test_pid, :alpha_ran)
          {:ok, "should never happen"}
        end)

      agent =
        Agent.new("openai:test-model",
          tools: [alpha],
          code_mode: :code,
          permissions: Permissions.build_policy(deny: ["alpha"])
        )

      assert {:ok, result} = AgentRunner.run(agent, "go")

      refute_receive :alpha_ran, 100
      assert tool_message(result) =~ "denied by the permission policy"
    end
  end

  describe "bindings are derived from the permission policy" do
    test "a granted tool becomes a real closure scoped to the caller" do
      test_pid = self()

      tools = [
        tool("granted", fn ctx, args ->
          send(test_pid, {:ran, ctx.deps, args})
          {:ok, "did it"}
        end),
        tool("denied")
      ]

      policy = Permissions.build_policy(deny: ["denied"])
      run_ctx = RunContext.new(%{session_id: "s-1"}, approval_gated?: true)

      [binding] = CodeMode.bindings(tools, policy, run_ctx)

      assert binding.functions["granted"].(%{"q" => 1}) == {:ok, "did it"}
      assert_receive {:ran, %{session_id: "s-1"}, %{"q" => 1}}

      assert {:error, %{"tool" => "denied"}} = binding.functions["denied"].(%{})
      refute_receive {:ran, _, _}
    end

    test "a failing tool reaches the program as a name and a message, nothing more" do
      tools = [tool("boom", fn _ctx, _args -> {:error, "kaboom"} end)]

      [binding] = CodeMode.bindings(tools, nil, RunContext.new(%{}, approval_gated?: true))

      assert {:error, error} = binding.functions["boom"].(%{})
      assert %{"tool" => "boom", "message" => message} = error
      assert message =~ "kaboom"
      # No struct, no stacktrace, no native content.
      assert Map.keys(error) |> Enum.sort() == ["message", "tool"]
    end

    test "direct_dispatch/3 folds the executor's three-shape return into two" do
      # ToolExecutor.execute/3 can answer {:ok, value, %ContextUpdate{}}. A
      # dispatch must hand back a 2-tuple, so anything sitting downstream of
      # this (a scheduler, the guest bridge) never sees the third shape and
      # cannot mistake a context update for a contract breach.
      update = Nous.Tool.ContextUpdate.set(Nous.Tool.ContextUpdate.new(), :seen, true)
      updating = tool("updates", fn _ctx, _args -> {:ok, "value", update} end)

      run_ctx = RunContext.new(%{}, approval_gated?: true)

      assert CodeMode.direct_dispatch(updating, %{}, run_ctx) == {:ok, "value"}

      [binding] = CodeMode.bindings([updating], nil, run_ctx)
      assert binding.functions["updates"].(%{}) == {:ok, "value"}
    end

    test "the :dispatch option is where a scheduler plugs in" do
      test_pid = self()
      tools = [tool("alpha")]

      dispatch = fn tool, args, ctx ->
        send(test_pid, {:dispatched, tool.name, args, ctx.deps})
        {:ok, "from the scheduler"}
      end

      [binding] = CodeMode.bindings(tools, nil, RunContext.new(%{k: :v}), dispatch: dispatch)

      assert binding.functions["alpha"].(%{"a" => 1}) == {:ok, "from the scheduler"}
      assert_receive {:dispatched, "alpha", %{"a" => 1}, %{k: :v}}
    end

    test "argument keys are normalized and a non-object is refused, not dispatched" do
      test_pid = self()
      tools = [tool("alpha")]

      dispatch = fn _tool, args, _ctx ->
        send(test_pid, {:args, args})
        {:ok, :ok}
      end

      [binding] = CodeMode.bindings(tools, nil, RunContext.new(%{}), dispatch: dispatch)

      binding.functions["alpha"].(%{path: "x"})
      assert_receive {:args, %{"path" => "x"}}

      # A guest calling tools["alpha"]() sends nothing; that is {}, not an error.
      binding.functions["alpha"].(nil)
      assert_receive {:args, %{}}

      assert {:error, %{"tool" => "alpha", "message" => message}} =
               binding.functions["alpha"].("just a string")

      assert message =~ "must be an object"
      refute_receive {:args, _}
    end

    test "the binding matches the SDK: same global, same error class, same names" do
      tools = [tool("my-tool")]
      [binding] = CodeMode.bindings(tools, nil, RunContext.new(%{}))

      assert binding.global == Nous.CodeMode.Sdk.global()
      assert binding.error_class == Nous.CodeMode.Sdk.error_class()
      assert Map.has_key?(binding.functions, "my-tool")
    end
  end

  describe "model-direct calls collapse under mode: :code" do
    test "collapsed?/3 only fires for a non-run_code model call in :code" do
      call = %{"id" => "c1", "name" => "alpha", "arguments" => %{}}

      assert CodeMode.collapsed?(:code, "alpha", call)
      refute CodeMode.collapsed?(:code, "run_code", call)
      refute CodeMode.collapsed?(:both, "alpha", call)
      refute CodeMode.collapsed?(:native, "alpha", call)
    end

    test "a sub-dispatch carrying a parent token is transport, and passes through" do
      token = CodeMode.new_parent_token()
      call = CodeMode.tag_transport(%{"id" => "c1", "name" => "alpha"}, token)

      assert CodeMode.transport_call?(call)
      refute CodeMode.collapsed?(:code, "alpha", call)

      refute CodeMode.transport_call?(%{"id" => "c1", "name" => "alpha"})
      refute CodeMode.transport_call?("not a call")
      assert CodeMode.new_parent_token() != token
    end
  end

  describe "the collapse happens before pre_tool_use hooks (runner integration)" do
    setup do
      configure_runtime()
      Nous.ModelDispatcher.put_dispatcher(__MODULE__.ToolCallDispatcher)
      :ok
    end

    defp recording_hook(test_pid) do
      Nous.Hook.new(:pre_tool_use,
        handler: fn _event, payload ->
          send(test_pid, {:hook_ran, payload.tool_name})
          :allow
        end,
        name: "recorder"
      )
    end

    defp guarded_tool(test_pid) do
      tool("guarded", fn _ctx, _args ->
        send(test_pid, :tool_ran)
        {:ok, "ran"}
      end)
    end

    test "under :code the hook never sees the call, and the tool never runs" do
      test_pid = self()

      agent =
        Agent.new("openai:test-model",
          tools: [guarded_tool(test_pid)],
          code_mode: :code,
          hooks: [recording_hook(test_pid)]
        )

      assert {:ok, result} = AgentRunner.run(agent, "go")

      refute_receive {:hook_ran, "guarded"}, 100
      refute_receive :tool_ran, 100

      message = tool_message(result)
      assert message =~ "Tool not found: guarded"
      assert message =~ "run_code"
    end

    test "the same call under :native does reach the hook and the tool" do
      test_pid = self()

      agent =
        Agent.new("openai:test-model",
          tools: [guarded_tool(test_pid)],
          code_mode: :native,
          hooks: [recording_hook(test_pid)]
        )

      assert {:ok, _result} = AgentRunner.run(agent, "go")

      assert_receive {:hook_ran, "guarded"}
      assert_receive :tool_ran
    end

    test "the parallel path collapses before its hooks too" do
      test_pid = self()
      Nous.ModelDispatcher.put_dispatcher(__MODULE__.ParallelToolCallDispatcher)

      agent =
        Agent.new("openai:test-model",
          tools: [guarded_tool(test_pid)],
          code_mode: :code,
          parallel_tool_calls: true,
          hooks: [recording_hook(test_pid)]
        )

      assert {:ok, result} = AgentRunner.run(agent, "go")

      refute_receive {:hook_ran, "guarded"}, 100
      refute_receive :tool_ran, 100
      assert tool_message(result) =~ "Tool not found: guarded"
    end

    test "run_code is what the model is offered under :code" do
      test_pid = self()
      Nous.ModelDispatcher.put_dispatcher(__MODULE__.SchemaCapturingDispatcher)
      Process.put(:schema_sink, test_pid)

      agent =
        Agent.new("openai:test-model",
          tools: [guarded_tool(test_pid)],
          code_mode: :code
        )

      assert {:ok, _result} = AgentRunner.run(agent, "go")

      assert_receive {:tool_schemas, schemas}
      assert schemas == ["run_code"]
    end
  end

  # Returns the first tool-result message's content from a run result.
  defp tool_message(result) do
    result.all_messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map_join("\n", & &1.content)
  end

  defmodule SchemaCapturingDispatcher do
    @moduledoc false

    def request(_model, _messages, settings) do
      names =
        (settings[:tools] || [])
        |> Enum.map(fn schema -> get_in(schema, ["function", "name"]) || schema["name"] end)

      send(Process.get(:schema_sink), {:tool_schemas, names})

      {:ok,
       Nous.Message.from_legacy(%{
         parts: [{:text, "done"}],
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end

  # Emits a run_code call whose program calls a tool, then a final answer.
  defmodule RunCodeDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      parts =
        if Enum.any?(messages, &(&1.role == :tool)) do
          [{:text, "final answer"}]
        else
          [
            {:tool_call,
             %{
               id: "c1",
               name: "run_code",
               arguments: %{
                 "code" => ~s|return await tools["alpha"]({});|,
                 "description" => "call alpha once"
               }
             }}
          ]
        end

      {:ok,
       Nous.Message.from_legacy(%{
         parts: parts,
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end
end
