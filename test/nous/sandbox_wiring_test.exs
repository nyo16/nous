defmodule Nous.SandboxWiringTest do
  # async: false — pins `:nous, :sandbox_mode` and `:nous, :sandbox_backend`,
  # both VM-global, and the backend probe result is memoized in
  # `:persistent_term`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.{Message, Usage}
  alias Nous.Agent.Context
  alias Nous.AgentRunner
  alias Nous.Sandbox
  alias Nous.Sandbox.{Policy, Unavailable}

  @moduledoc """
  The `Agent -> AgentRunner -> RunContext -> Nous.Tools.Bash` sandbox wiring.

  Every hop is a one-line assignment, and each one had zero coverage: deleting
  `sandbox: agent.sandbox` in `Nous.AgentRunner.ToolExecution`, deleting the
  `:sandbox` clause of `apply_runtime_overrides/2`, or making
  `Nous.Agent.normalize_sandbox/1` return `nil` all turned a documented security
  control into a silent no-op with the whole suite green. `Nous.Tools.Bash`'s
  moduledoc advertises both `Nous.new(model, sandbox: :workspace_write)` and
  `Nous.run(agent, prompt, sandbox: :read_only)`; these tests are what makes
  those sentences true.

  No live LLM: `:sandbox_backend` is pinned to `Nous.Sandbox.Unavailable` and
  `:sandbox_mode` to `:danger_full_access`, so "the agent's policy arrived" and
  "it did not" have opposite, observable outcomes — a refusal with no side
  effect, versus the command actually running.
  """

  # Emits one `bash` tool call, then a plain text answer once the tool result is
  # in the history. The command comes from the process dictionary because the
  # runner calls the dispatcher in the caller's process (which is what makes
  # `Nous.ModelDispatcher.put_dispatcher/1` process-scoped in the first place).
  defmodule BashCallingDispatcher do
    @moduledoc false

    @key {__MODULE__, :command}

    def put_command(command), do: Process.put(@key, command)

    def request(_model, messages, _settings) do
      parts =
        if Enum.any?(messages, &(&1.role == :tool)) do
          [{:text, "done"}]
        else
          [
            {:tool_call,
             %{
               id: "call_bash_1",
               name: "bash",
               arguments: %{"command" => Process.get(@key)}
             }}
          ]
        end

      {:ok,
       Message.from_legacy(%{
         parts: parts,
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end

    def count_tokens(_messages), do: 0
  end

  setup do
    original_mode = Application.fetch_env(:nous, :sandbox_mode)
    original_backend = Application.fetch_env(:nous, :sandbox_backend)

    Sandbox.warm()
    Sandbox.reset_backend_cache()

    # The permissive end of the scale, application-wide: anything more
    # restrictive that reaches the tool can only have come from the agent or the
    # run. And a backend that can confine nothing, so "more restrictive" is
    # observable as a refusal rather than as a real sandbox.
    Application.put_env(:nous, :sandbox_mode, :danger_full_access)
    Application.put_env(:nous, :sandbox_backend, Unavailable)

    workspace =
      Path.join(System.tmp_dir!(), "sandbox_wiring_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
      restore(:sandbox_mode, original_mode)
      restore(:sandbox_backend, original_backend)
      Sandbox.reset_backend_cache()
    end)

    Nous.ModelDispatcher.put_dispatcher(BashCallingDispatcher)

    {:ok, workspace: workspace, marker: Path.join(workspace, "agent_bash_ran")}
  end

  describe "Nous.new/2 normalizes :sandbox onto the agent" do
    test "a bare mode atom" do
      assert %Policy{mode: :read_only} = Nous.new("openai:gpt-4o", sandbox: :read_only).sandbox
    end

    test "a keyword list", %{workspace: workspace} do
      agent =
        Nous.new("openai:gpt-4o", sandbox: [mode: :workspace_write, workspace_root: workspace])

      assert agent.sandbox.mode == :workspace_write
      # Canonicalised at construction, which is what makes an SBPL
      # `(subpath ...)` clause match what the kernel actually sees.
      assert agent.sandbox.workspace_root == Policy.canonical(workspace)
    end

    test "an already-built %Policy{} passes through unchanged", %{workspace: workspace} do
      policy = Policy.new(mode: :read_only, workspace_root: workspace)
      assert Nous.new("openai:gpt-4o", sandbox: policy).sandbox == policy
    end

    test "no :sandbox option leaves it nil, so application config decides" do
      # Not `:danger_full_access`: `nil` means "unset". Baking the default in
      # here would make `config :nous, :sandbox_mode` unreachable for every
      # agent built without the option, which is nearly all of them.
      assert Nous.new("openai:gpt-4o").sandbox == nil
    end

    test "a bad mode raises at construction, not mid-run inside a tool call" do
      assert_raise ArgumentError, ~r/invalid sandbox mode/, fn ->
        Nous.new("openai:gpt-4o", sandbox: :read_onlyy)
      end
    end
  end

  describe "the policy on the agent is the policy the tool resolves" do
    test "Context.to_run_context/2 carries it, and Bash honours it", %{
      workspace: workspace,
      marker: marker
    } do
      agent = Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash], sandbox: :read_only)

      # Built exactly the way `Nous.AgentRunner.ToolExecution` builds it.
      ctx = Context.new(deps: %{workspace_root: workspace})
      run_ctx = Context.to_run_context(ctx, sandbox: agent.sandbox)

      assert Policy.resolve(run_ctx).mode == :read_only

      assert {:error, message} =
               Nous.Tools.Bash.execute(run_ctx, %{"command" => "touch '#{marker}'"})

      assert message =~ "no OS sandbox can enforce"
      assert message =~ "read_only"
      refute File.exists?(marker)
    end

    test "the control: without the agent's policy the same call runs", %{
      workspace: workspace,
      marker: marker
    } do
      # This is the mutation `delete sandbox: agent.sandbox` made visible: the
      # run context is identical except for the one keyword.
      ctx = Context.new(deps: %{workspace_root: workspace})
      run_ctx = Context.to_run_context(ctx)

      assert Policy.resolve(run_ctx).mode == :danger_full_access
      assert {:ok, _} = Nous.Tools.Bash.execute(run_ctx, %{"command" => "touch '#{marker}'"})
      assert File.exists?(marker)
    end
  end

  describe "end to end through AgentRunner" do
    test "the agent's sandbox policy reaches the bash tool", %{
      workspace: workspace,
      marker: marker
    } do
      agent = Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash], sandbox: :read_only)

      log =
        capture_log(fn ->
          assert {:ok, result} = run_agent(agent, workspace, "touch '#{marker}'")
          assert tool_output(result) =~ "no OS sandbox can enforce"
        end)

      # The load-bearing assertion: an unconfinable :read_only run must not
      # silently fall through to an unconfined spawn.
      refute File.exists?(marker)
      refute log =~ "requires approval"
    end

    test "the control: an agent with no sandbox runs the same command", %{
      workspace: workspace,
      marker: marker
    } do
      agent = Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash])

      capture_log(fn ->
        assert {:ok, _result} = run_agent(agent, workspace, "touch '#{marker}'")
      end)

      assert File.exists?(marker)
    end
  end

  describe "a per-run :sandbox override wins over the agent's" do
    test "narrowing: :read_only over an agent built :danger_full_access", %{
      workspace: workspace,
      marker: marker
    } do
      agent =
        Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash], sandbox: :danger_full_access)

      capture_log(fn ->
        assert {:ok, result} =
                 run_agent(agent, workspace, "touch '#{marker}'", sandbox: :read_only)

        assert tool_output(result) =~ "no OS sandbox can enforce"
      end)

      refute File.exists?(marker)
    end

    test "widening: :danger_full_access over an agent built :read_only", %{
      workspace: workspace,
      marker: marker
    } do
      # The reverse direction, because an override that only ever narrowed would
      # also pass the test above while ignoring the option's value.
      agent = Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash], sandbox: :read_only)

      capture_log(fn ->
        assert {:ok, _result} =
                 run_agent(agent, workspace, "touch '#{marker}'", sandbox: :danger_full_access)
      end)

      assert File.exists?(marker)
    end

    test "an explicit nil clears the agent's policy back to application config", %{
      workspace: workspace,
      marker: marker
    } do
      agent = Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash], sandbox: :read_only)

      capture_log(fn ->
        assert {:ok, _result} = run_agent(agent, workspace, "touch '#{marker}'", sandbox: nil)
      end)

      # App config is :danger_full_access for this test module, so clearing the
      # agent's :read_only is observable as the command running.
      assert File.exists?(marker)
    end

    test "the override accepts the same shapes as Nous.new/2", %{workspace: workspace} do
      agent =
        Nous.new("openai:gpt-4o", tools: [Nous.Tools.Bash], sandbox: :danger_full_access)

      shapes = [
        {"atom", :read_only},
        {"keyword", [mode: :read_only, workspace_root: workspace]},
        {"struct", Policy.new(mode: :read_only, workspace_root: workspace)}
      ]

      for {label, shape} <- shapes do
        marker = Path.join(workspace, "shape_#{label}")

        capture_log(fn ->
          assert {:ok, result} =
                   run_agent(agent, workspace, "touch '#{marker}'", sandbox: shape)

          assert tool_output(result) =~ "no OS sandbox can enforce",
                 "the #{label} shape did not narrow the run to :read_only"
        end)

        refute File.exists?(marker), "the #{label} shape let the command run"
      end
    end
  end

  # ---------------------------------------------------------------------------

  defp run_agent(agent, workspace, command, opts \\ []) do
    BashCallingDispatcher.put_command(command)

    ctx =
      Context.new(
        messages: [Message.user("run the command")],
        deps: %{workspace_root: workspace},
        # `bash` is `requires_approval: true`, and a tool with no handler is
        # default-DENIED — without this the marker would be absent for a reason
        # that has nothing to do with the sandbox.
        approval_handler: fn %{name: "bash"} -> :approve end
      )

    AgentRunner.run_with_context(agent, ctx, opts)
  end

  defp tool_output(result) do
    result.all_messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map_join("\n", & &1.content)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:nous, key, value)
  defp restore(key, :error), do: Application.delete_env(:nous, key)
end
