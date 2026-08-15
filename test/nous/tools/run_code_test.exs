defmodule Nous.Tools.RunCodeTest do
  # Sync: the "no provider configured" and timeout tests read/write
  # application-wide code-runtime settings.
  use ExUnit.Case, async: false

  alias Nous.CodeRuntime.{Failure, Request, Result}
  alias Nous.{Permissions, RunContext, Tool, ToolExecutor}
  alias Nous.Tools.RunCode

  @sink :run_code_test_sink

  # A provider driven entirely by its config, so each test states the substrate
  # behaviour it is about:
  #
  #   result: %Result{}  — deliver this
  #   result: :never     — accept the run and never answer (deadline path)
  #   start: {:error, _} — refuse the request at the seam
  #   start: :garbage    — return something the seam does not allow
  defmodule StubProvider do
    @moduledoc false
    @behaviour Nous.CodeRuntime

    @impl true
    def language(_config), do: "javascript"

    @impl true
    def isolation(_config), do: "none — in-process test double"

    @impl true
    def start_run(%Request{} = request, config) do
      notify(config, {:started, request})

      case Keyword.get(config, :start, :ok) do
        :ok -> deliver(request, Keyword.get(config, :result, Result.ok("default")))
        other -> other
      end
    end

    @impl true
    def cancel(ref, reason) do
      if pid = Process.whereis(:run_code_test_sink) do
        send(pid, {:cancelled, ref, reason})
      end

      :ok
    end

    defp deliver(_request, :never), do: {:ok, make_ref()}

    defp deliver(request, %Result{} = result) do
      ref = make_ref()
      send(request.owner, {:code_run, ref, result})
      {:ok, ref}
    end

    defp notify(config, message) do
      case Keyword.get(config, :notify) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:nous, :code_runtime)
      Application.delete_env(:nous, :code_run_timeout_ms)
    end)

    {:ok, ctx: RunContext.new(%{}, approval_gated?: true)}
  end

  defp args(overrides \\ %{}) do
    Map.merge(%{"code" => "return 1;", "description" => "add one"}, overrides)
  end

  defp tool(name, fun) do
    %Tool{
      name: name,
      description: "The #{name} tool.",
      function: fun,
      takes_ctx: true,
      timeout: nil,
      parameters: %{"type" => "object", "properties" => %{}, "required" => []}
    }
  end

  describe "the description is not decoration" do
    test "an empty description is rejected before anything runs", %{ctx: ctx} do
      runtime = {StubProvider, notify: self()}

      assert {:error, message} =
               RunCode.run(ctx, args(%{"description" => ""}), runtime: runtime)

      assert message =~ "non-empty `description`"
      assert message =~ "audit log"
      refute_received {:started, _request}
    end

    test "a whitespace-only description is rejected too", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, args(%{"description" => "   \n\t"}),
                 runtime: {StubProvider, notify: self()}
               )

      assert message =~ "non-empty `description`"
      refute_received {:started, _request}
    end

    test "a missing description is rejected", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, %{"code" => "return 1;"}, runtime: {StubProvider, []})

      assert message =~ "`description`"
    end

    test "a missing or non-string program is rejected", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, %{"description" => "d"}, runtime: {StubProvider, []})

      assert message =~ "`code` parameter"

      assert {:error, _} =
               RunCode.run(ctx, args(%{"code" => 42}), runtime: {StubProvider, []})
    end

    test "the schema requires both parameters, so the executor rejects them too", %{ctx: ctx} do
      run_code = Tool.from_module(RunCode)

      assert {:error, error} = ToolExecutor.execute(run_code, %{"code" => "x"}, ctx)
      assert Exception.message(error) =~ "description"
    end
  end

  describe "with no provider configured" do
    test "it returns a clear, actionable error and does not raise", %{ctx: ctx} do
      Application.delete_env(:nous, :code_runtime)

      assert {:error, message} = RunCode.execute(ctx, args())

      assert message =~ "no code runtime is configured"
      assert message =~ "config :nous, :code_runtime"
      assert message =~ "Nous.CodeRuntime"
    end

    test "a misconfigured provider is named rather than crashing", %{ctx: ctx} do
      Application.put_env(:nous, :code_runtime, Enum)

      assert {:error, message} = RunCode.execute(ctx, args())
      assert message =~ "does not implement Nous.CodeRuntime"
    end

    test "the configured provider is used when execute/2 gets no opts", %{ctx: ctx} do
      Application.put_env(:nous, :code_runtime, {StubProvider, result: Result.ok("via config")})

      assert {:ok, %{result: "via config"}} = RunCode.execute(ctx, args())
    end
  end

  describe "results" do
    test "a successful run returns logs and the value", %{ctx: ctx} do
      result = Result.ok(%{"count" => 3}, ["step 1", "step 2"])

      assert {:ok, output} = RunCode.run(ctx, args(), runtime: {StubProvider, result: result})
      assert output == %{logs: ["step 1", "step 2"], result: %{"count" => 3}}
    end

    test "a failed run is data, not a tool error, and keeps the logs" do
      ctx = RunContext.new(%{})
      result = Result.failed(:exception, "ReferenceError: x is not defined", ["got this far"])

      assert {:ok, output} = RunCode.run(ctx, args(), runtime: {StubProvider, result: result})

      assert output == %{
               logs: ["got this far"],
               error: %{kind: "exception", message: "ReferenceError: x is not defined"}
             }
    end

    test "every failure kind survives the round trip", %{ctx: ctx} do
      for kind <- Failure.kinds() do
        result = Result.failed(kind, "the #{kind} case")

        assert {:ok, %{error: %{kind: rendered}}} =
                 RunCode.run(ctx, args(), runtime: {StubProvider, result: result})

        assert rendered == Atom.to_string(kind)
      end
    end

    test "a run that never answers is cancelled and reported as a timeout", %{ctx: ctx} do
      Process.register(self(), @sink)
      Application.put_env(:nous, :code_run_timeout_ms, 50)

      assert {:ok, output} = RunCode.run(ctx, args(), runtime: {StubProvider, result: :never})

      assert %{logs: [], error: %{kind: "timeout", message: message}} = output
      assert message =~ "50ms"

      # Giving up on the receive is not the same as stopping the work.
      assert_received {:cancelled, _ref, :timeout}
    end

    test "a seam refusal is a tool error, because nothing ran", %{ctx: ctx} do
      runtime = {StubProvider, start: {:error, {:contract, "disposed runtime"}}}

      assert {:error, message} = RunCode.run(ctx, args(), runtime: runtime)
      assert message =~ "the code runtime refused the request: disposed runtime"
    end

    test "a provider that breaks the contract is reported, not obeyed", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, args(), runtime: {StubProvider, start: :whatever})

      assert message =~ "returned :whatever from start_run/2"
    end

    test "an invalid :runtime option is refused", %{ctx: ctx} do
      assert {:error, message} = RunCode.run(ctx, args(), runtime: "not a provider")
      assert message =~ "invalid :runtime option"
    end
  end

  describe "the request handed to the provider" do
    test "carries the program, this process as owner, and permission-derived bindings", %{
      ctx: ctx
    } do
      test_pid = self()

      tools = [
        tool("granted", fn _ctx, _args -> {:ok, "granted ran"} end),
        tool("denied", fn _ctx, _args -> {:ok, "denied ran"} end)
      ]

      policy = Permissions.build_policy(deny: ["denied"])

      assert {:ok, _output} =
               RunCode.run(ctx, args(%{"code" => "program text"}),
                 runtime: {StubProvider, notify: test_pid},
                 tools: tools,
                 policy: policy
               )

      assert_received {:started, %Request{} = request}
      assert request.program == "program text"
      assert request.owner == self()

      assert [binding] = request.bindings
      assert Enum.sort(Map.keys(binding.functions)) == ["denied", "granted"]

      assert binding.functions["granted"].(%{}) == {:ok, "granted ran"}
      assert {:error, %{"tool" => "denied"}} = binding.functions["denied"].(%{})
    end

    test "a run with no tools still gets a binding, just an empty one", %{ctx: ctx} do
      assert {:ok, _output} =
               RunCode.run(ctx, args(), runtime: {StubProvider, notify: self()})

      assert_received {:started, %Request{bindings: [binding]}}
      assert binding.functions == %{}
    end

    test "the :dispatch option reaches the bindings", %{ctx: ctx} do
      test_pid = self()
      tools = [tool("alpha", fn _ctx, _args -> {:ok, :unused} end)]

      dispatch = fn tool, _args, _ctx ->
        send(test_pid, {:dispatched, tool.name})
        {:ok, "scheduled"}
      end

      assert {:ok, _output} =
               RunCode.run(ctx, args(),
                 runtime: {StubProvider, notify: test_pid},
                 tools: tools,
                 dispatch: dispatch
               )

      assert_received {:started, %Request{bindings: [binding]}}
      assert binding.functions["alpha"].(%{}) == {:ok, "scheduled"}
      assert_received {:dispatched, "alpha"}
    end
  end

  describe "as a tool" do
    test "its schema declares both parameters as required" do
      %Tool{parameters: parameters} = Tool.from_module(RunCode)

      assert parameters["type"] == "object"
      assert Enum.sort(parameters["required"]) == ["code", "description"]
      assert parameters["properties"]["code"]["type"] == "string"
      assert parameters["properties"]["description"]["type"] == "string"
    end

    test "it is an execute-category tool, so a policy can gate it" do
      %Tool{} = run_code = Tool.from_module(RunCode)

      assert run_code.category == :execute
      assert Permissions.requires_approval?(Permissions.permissive_policy(), "run_code", :execute)
    end
  end
end
