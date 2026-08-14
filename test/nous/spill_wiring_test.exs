defmodule Nous.SpillWiringTest do
  # async: false — the bash tests set `:nous, :sandbox_mode` / `:sandbox_backend`
  # (VM-global, and the backend probe is memoized in `:persistent_term`), and
  # every test asserts on the *absence* of `config :nous, :spill`, which is also
  # VM-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.AgentRunner.ToolExecution
  alias Nous.Sandbox
  alias Nous.Sandbox.Confined
  alias Nous.Spill.Locator
  alias Nous.{RunContext, Tool}
  alias Nous.Tools.Bash

  # Small enough that one line of test data blows it, large enough that
  # `Nous.Spill` still has preview budget left after reserving its notice.
  @cap 2_048

  # A spill backend that records every save and can hand the bytes back.
  #
  # The store is a module, so it has no place to keep the test pid: it arrives
  # through the store's own `:opts`, the one channel `Nous.Spill` gives a
  # backend. Content lives in a named Agent so `fetch/1` round-trips.
  defmodule RecordingStore do
    @moduledoc false
    use Agent

    @behaviour Nous.Spill

    alias Nous.Spill.Locator

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    @impl Nous.Spill
    def save_text(%{content: content, suggested_name: name, opts: opts} = attrs) do
      id = "recorded-#{System.unique_integer([:positive])}"
      Agent.update(__MODULE__, &Map.put(&1, id, content))

      locator = %Locator{store: __MODULE__, id: id, bytes: byte_size(content), name: name}

      if pid = Keyword.get(opts, :report_to) do
        send(
          pid,
          {:saved, locator, Map.take(attrs, [:owner, :source, :suggested_name, :content])}
        )
      end

      {:ok, locator}
    end

    @impl Nous.Spill
    def fetch(%Locator{id: id}) do
      case Agent.get(__MODULE__, &Map.fetch(&1, id)) do
        {:ok, content} -> {:ok, content}
        :error -> {:error, :not_found}
      end
    end

    @impl Nous.Spill
    def retrieval_hint(%Locator{id: id}), do: "Fetch it from the test store under id #{id}."
  end

  # A store whose writes always fail — the case that must not be allowed to
  # damage an otherwise successful tool call.
  defmodule ExplodingStore do
    @moduledoc false
    @behaviour Nous.Spill

    @impl Nous.Spill
    def save_text(_attrs), do: {:error, :enospc}

    @impl Nous.Spill
    def fetch(_locator), do: {:error, :enospc}

    @impl Nous.Spill
    def retrieval_hint(_locator), do: "nowhere"
  end

  # Denied AND over the output ceiling, the way `Nous.Tools.BashSandboxTest`
  # stages it: the denial goes to stderr first so it survives truncation, then
  # the command floods stdout past the 1 MB cap. Verbatim denial signatures from
  # `Nous.Sandbox.Seatbelt`.
  defmodule ChattyDenyingBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    @script "echo 'Operation not permitted' >&2; head -c 1200000 /dev/zero | tr '\\0' 'x'; exit 1"

    @impl Nous.Sandbox
    def confine(_argv, policy) do
      {:ok,
       %Confined{
         argv: ["/bin/sh", "-c", @script],
         mode: policy.mode,
         enforcement: :sandbox_exec,
         denial_signatures: ["operation not permitted", "permission denied"]
       }}
    end

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: {:error, :unusable}
  end

  setup do
    original_spill = Application.fetch_env(:nous, :spill)
    original_mode = Application.fetch_env(:nous, :sandbox_mode)
    original_backend = Application.fetch_env(:nous, :sandbox_backend)

    # The application-config fallback must be absent, or the "opt-in" test would
    # be measuring a leaked global instead of the default.
    Application.delete_env(:nous, :spill)

    Sandbox.warm()
    Sandbox.reset_backend_cache()

    on_exit(fn ->
      restore(:spill, original_spill)
      restore(:sandbox_mode, original_mode)
      restore(:sandbox_backend, original_backend)
      Sandbox.reset_backend_cache()
    end)

    start_supervised!(RecordingStore)

    :ok
  end

  describe "oversized tool results" do
    test "a search result over the cap is replaced by a preview and a locator" do
      text = oversized_text()

      {message, _updates} = run_tool("file_grep", text, spill_deps(RecordingStore))

      # The store got the whole thing, not the preview.
      assert_receive {:saved, locator, saved}
      assert saved.content == text
      assert saved.source == "file_grep"
      assert saved.suggested_name == "file_grep-result.txt"

      # ...and the model gets a preview plus the locator, under the cap.
      assert message.content =~ locator.id
      assert message.content =~ "Fetch it from the test store under id"
      assert message.content =~ "HEAD-MARKER"
      assert message.content =~ "TAIL-MARKER"
      assert byte_size(message.content) <= @cap
      refute message.content == text

      # The omitted-byte count has to be honest: not zero, not more than the
      # original, and large enough to account for everything the cap excluded.
      omitted = omitted_bytes(message.content)
      assert omitted >= byte_size(text) - @cap
      assert omitted <= byte_size(text)

      assert {:ok, text} == Nous.Spill.fetch(locator)
    end

    test "a result under the cap is passed through byte for byte" do
      small = "3 matches in 2 files\n"

      {message, _updates} = run_tool("file_grep", small, spill_deps(RecordingStore))

      assert message.content == small
      refute_receive {:saved, _locator, _saved}
    end

    test "the owner falls back to the agent name, and prefers the session id" do
      text = oversized_text()

      {_message, _updates} = run_tool("file_grep", text, spill_deps(RecordingStore))
      assert_receive {:saved, _locator, %{owner: "spill_wiring_agent"}}

      deps = spill_deps(RecordingStore, %{session_id: "session-abc"})
      {_message, _updates} = run_tool("file_grep", text, deps)
      assert_receive {:saved, _locator, %{owner: "session-abc"}}
    end

    test "a non-binary result is left structured rather than stringified" do
      rows = Enum.map(1..500, &%{"id" => &1, "body" => String.duplicate("y", 64)})

      {message, _updates} = run_tool("file_grep", rows, spill_deps(RecordingStore))

      # Message.tool/3 encodes a structured result; what matters is that no
      # locator was substituted for it and nothing was stored.
      refute_receive {:saved, _locator, _saved}
      refute message.content =~ "recorded-"
      assert message.content =~ "body"
    end
  end

  describe "the read→spill→read loop guard" do
    test "a file_read result over the cap is never spilled" do
      text = oversized_text()

      {message, _updates} = run_tool("file_read", text, spill_deps(RecordingStore))

      # Spilling this would hand the model a locator whose retrieval hint says
      # "read it with file_read", whose result is also over the cap, forever.
      assert message.content == text
      refute_receive {:saved, _locator, _saved}
    end
  end

  describe "best effort" do
    test "a store that always fails leaves the result inline and the call intact" do
      text = oversized_text()

      log =
        capture_log(fn ->
          {message, updates} = run_tool("file_grep", text, spill_deps(ExplodingStore))

          assert message.content == text
          assert message.role == :tool
          assert updates == %{}
          refute message.content =~ "Tool execution failed"
        end)

      assert log =~ "keeping the result inline"
    end

    test "with no spill config at all, an oversized result is untouched" do
      text = oversized_text()

      {message, _updates} = run_tool("file_grep", text, %{})

      assert message.content == text
      refute_receive {:saved, _locator, _saved}
    end
  end

  describe "Nous.Tools.Bash over the output ceiling" do
    test "the truncated prefix is stored and the locator round-trips" do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)

      ctx = bash_ctx(spill_deps(RecordingStore, %{session_id: "session-bash"}))

      assert {:ok, output} = Bash.execute(ctx, %{"command" => "yes x | head -c 1200000"})

      assert_receive {:saved, locator, saved}, 5_000
      assert saved.source == "bash"
      assert saved.owner == "session-bash"
      assert saved.suggested_name == "bash-output.txt"

      # What used to be dropped on the floor is now retrievable, exactly.
      assert {:ok, stored} = Nous.Spill.fetch(locator)
      assert stored == saved.content
      assert byte_size(stored) > 1_000_000

      assert output =~ locator.id
      # The truncation fact survives spilling, and does not promise a full
      # transcript: NetRunner killed the command at the cap.
      assert output =~ "Only the first 1000000 bytes were captured"
      assert String.ends_with?(output, "\n\n[Output truncated at 1000000 bytes]")
      assert byte_size(output) <= @cap
    end

    test "the runner does not spill the spill" do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)

      # The production path: Bash spills its truncated prefix, and the result
      # then passes through the runner's own spill on its way to a message. A
      # replacement already fills the inline cap, so a second spill here would
      # hand the model a preview of a preview and could drop the first locator
      # out of the middle of it.
      call = %{
        "id" => "call_1",
        "name" => "bash",
        "arguments" => %{"command" => "yes x | head -c 1200000"}
      }

      ctx = bash_ctx(spill_deps(RecordingStore))
      agent = Nous.Agent.new("openai:test-model", name: "spill_wiring_agent")

      {message, _updates} =
        ToolExecution.execute_single_tool([Tool.from_module(Bash)], call, ctx, agent)

      assert_receive {:saved, locator, _saved}, 5_000
      refute_receive {:saved, _locator, _saved}

      assert message.content =~ locator.id
      assert String.ends_with?(message.content, "\n\n[Output truncated at 1000000 bytes]")
    end

    test "without a store, truncation keeps today's marker byte for byte" do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)

      assert {:ok, output} =
               Bash.execute(bash_ctx(%{}), %{"command" => "yes x | head -c 1200000"})

      assert String.ends_with?(output, "\n\n[Output truncated at 1000000 bytes]")
      assert byte_size(output) > 1_000_000
      refute_receive {:saved, _locator, _saved}
    end

    test "a spilled truncation still carries its sandbox verdict" do
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, ChattyDenyingBackend)

      ctx = bash_ctx(spill_deps(RecordingStore))

      assert {:ok, output} = Bash.execute(ctx, %{"command" => "echo x > /etc/nope"})

      assert_receive {:saved, locator, _saved}, 5_000

      # Annotate, never replace: the verdict appends to whatever the caller
      # would otherwise have received — spilled replacement included.
      assert output =~ locator.id
      assert output =~ "Output truncated at 1000000 bytes"
      assert String.ends_with?(output, "\n[sandbox: file access denied under read_only mode]")
    end
  end

  # ---------------------------------------------------------------------------

  # Distinct head and tail so a preview that dropped either end is visible.
  defp oversized_text do
    "HEAD-MARKER\n" <> String.duplicate("a matching line\n", 400) <> "TAIL-MARKER\n"
  end

  defp spill_deps(store, extra \\ %{}) do
    Map.merge(
      %{spill_config: %{store: store, opts: [report_to: self()], max_inline_bytes: @cap}},
      extra
    )
  end

  # The one place a completed tool result becomes message content, which both
  # the sequential and the parallel runner path go through.
  defp run_tool(tool_name, result, deps) do
    tool =
      Tool.from_function(fn _ctx, _args -> result end,
        name: tool_name,
        description: "returns a canned result"
      )

    call = %{"id" => "call_1", "name" => tool_name, "arguments" => %{}}
    agent = Nous.Agent.new("openai:test-model", name: "spill_wiring_agent")

    ToolExecution.execute_single_tool([tool], call, RunContext.new(deps), agent)
  end

  defp bash_ctx(deps), do: RunContext.new(deps, approval_gated?: true)

  defp omitted_bytes(content) do
    case Regex.run(~r/Omitted (\d+) bytes/, content) do
      [_match, omitted] -> String.to_integer(omitted)
      nil -> flunk("no omitted-byte count in:\n#{String.slice(content, 0, 400)}")
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:nous, key, value)
  defp restore(key, :error), do: Application.delete_env(:nous, key)
end
