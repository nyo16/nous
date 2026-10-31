defmodule Nous.Plugins.SkillsAllowedToolsTest do
  @moduledoc """
  Request-path tests for skill `allowed_tools` (#90): the restriction must show
  up in the tool list the model is sent and in which tool functions run, not
  only in a helper's return value.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nous.{Agent, AgentRunner, Permissions, Skill, Tool, Usage}

  @owner_key :skills_allowed_tools_test_owner

  # Scripted model: reports the tool names of every request to the test
  # process. When the prompt contains "CALL" and no tool has answered yet, it
  # calls write_file and read_file; otherwise it answers with text.
  defmodule ScriptedDispatcher do
    @moduledoc false

    def request(model, messages, settings) do
      names = Enum.map(settings[:tools] || [], &get_in(&1, ["function", "name"]))
      send(owner(), {:request_tools, names})
      send(owner(), {:request_model, model.provider, model.model})

      tool_answered? = Enum.any?(messages, &(&1.role == :tool))
      wants_calls? = Enum.any?(messages, &(&1.role == :user and user_text(&1) =~ "CALL"))

      if wants_calls? and not tool_answered? do
        {:ok,
         response([
           {:tool_call, %{id: "c1", name: "write_file", arguments: %{}}},
           {:tool_call, %{id: "c2", name: "read_file", arguments: %{}}}
         ])}
      else
        {:ok, response([{:text, "done"}])}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0

    defp owner do
      Process.get(:skills_allowed_tools_test_owner) ||
        List.last(Process.get(:"$callers", []))
    end

    defp user_text(%{content: text}) when is_binary(text), do: text
    defp user_text(_), do: ""

    defp response(parts) do
      Nous.Message.from_legacy(%{
        parts: parts,
        usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      })
    end
  end

  setup do
    Process.put(@owner_key, self())
    Nous.ModelDispatcher.put_dispatcher(ScriptedDispatcher)
    :ok
  end

  defp tool(name) do
    test_pid = self()

    Tool.from_function(
      fn _args ->
        send(test_pid, {:tool_ran, name})
        %{ok: name}
      end,
      name: name,
      description: "#{name} tool"
    )
  end

  defp agent_tools, do: [tool("read_file"), tool("write_file"), tool("file_grep")]

  defp skill(name, allowed_tools, activation \\ :auto) do
    %Skill{
      name: name,
      description: "",
      instructions: "#{name} instructions",
      activation: activation,
      source: :inline,
      status: :loaded,
      allowed_tools: allowed_tools
    }
  end

  defp run(skills, prompt, opts \\ []) do
    agent = Agent.new("openai:test-model", [tools: agent_tools(), skills: skills] ++ opts)
    AgentRunner.run(agent, prompt)
  end

  describe "an active skill with allowed_tools" do
    test "the request lists only the allowed agent tool" do
      assert {:ok, _} = run([skill("reader", ["read_file"])], "hello")

      assert_receive {:request_tools, ["read_file"]}
    end

    test "a scripted call to another tool is refused and its function never runs" do
      assert {:ok, result} = run([skill("reader", ["read_file"])], "CALL now")

      assert_receive {:tool_ran, "read_file"}
      refute_receive {:tool_ran, "write_file"}, 100

      write_result =
        Enum.find(result.all_messages, &(&1.role == :tool and &1.tool_call_id == "c1"))

      assert Nous.Message.extract_text(write_result) =~ "Tool not found: write_file"
    end

    test "a skill activated by the user's message restricts that same request" do
      reviewer = skill("reviewer", ["file_grep"], {:on_match, &String.contains?(&1, "review")})

      assert {:ok, _} = run([reviewer], "please review this")

      assert_receive {:request_tools, ["file_grep"]}
    end

    test "allowed_tools: [] allows no tool at all" do
      assert {:ok, _} = run([skill("nothing", [])], "CALL now")

      assert_receive {:request_tools, []}
      refute_receive {:tool_ran, _}, 100
    end

    test "a non-list allowed_tools set in code allows nothing instead of everything" do
      assert {:ok, _} = run([skill("typo", "read_file")], "CALL now")

      assert_receive {:request_tools, []}
      refute_receive {:tool_ran, _}, 100
    end

    test "the agent's own policy still applies on top of the skill allowlist" do
      policy = Permissions.build_policy(deny: ["read_file"])

      assert {:ok, _} =
               run([skill("reader", ["read_file", "file_grep"])], "hello", permissions: policy)

      assert_receive {:request_tools, ["file_grep"]}
    end

    test "tools receive the skill allowlist in their run context, so delegation inherits it" do
      test_pid = self()

      delegate =
        Tool.from_function(
          fn ctx, _args ->
            send(test_pid, {:run_ctx_permissions, ctx.permissions})
            %{ok: true}
          end,
          name: "read_file",
          description: "captures the run context"
        )

      agent =
        Agent.new("openai:test-model",
          tools: [delegate, tool("write_file")],
          skills: [skill("reader", ["read_file"])]
        )

      assert {:ok, _} = AgentRunner.run(agent, "CALL now")

      assert_receive {:run_ctx_permissions, policy}
      assert Permissions.blocked?(policy, "write_file")
      refute Permissions.blocked?(policy, "read_file")
      # Approval-neutral: the skill allowlist adds no approval gate of its own.
      refute Permissions.requires_approval?(policy, "read_file", :execute)
    end

    @tag :tmp_dir
    test "a file-based skill's frontmatter allowed_tools is enforced", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "reader.md"), """
      ---
      name: reader
      activation: auto
      allowed_tools: [read_file]
      ---
      Only read.
      """)

      assert {:ok, _} = run([dir], "CALL now")

      assert_receive {:request_tools, ["read_file"]}
      refute_receive {:tool_ran, "write_file"}, 100
    end
  end

  describe "no restricting skill active" do
    test "the full tool set is sent when no skill is active" do
      inactive = skill("reader", ["read_file"], :manual)

      assert {:ok, _} = run([inactive], "hello")

      assert_receive {:request_tools, names}
      assert Enum.sort(names) == ["file_grep", "read_file", "write_file"]
    end

    test "an active skill with allowed_tools: nil does not restrict" do
      assert {:ok, _} = run([skill("open", nil)], "CALL now")

      assert_receive {:request_tools, names}
      assert Enum.sort(names) == ["file_grep", "read_file", "write_file"]
      assert_receive {:tool_ran, "write_file"}
    end
  end

  describe "several active skills" do
    test "the union of their allowlists is allowed" do
      skills = [skill("reader", ["read_file"]), skill("searcher", ["file_grep"])]

      assert {:ok, _} = run(skills, "hello")

      assert_receive {:request_tools, names}
      assert Enum.sort(names) == ["file_grep", "read_file"]
    end

    test "a skill with allowed_tools: nil does not widen another skill's restriction" do
      skills = [skill("reader", ["read_file"]), skill("open", nil)]

      assert {:ok, _} = run(skills, "CALL now")

      assert_receive {:request_tools, ["read_file"]}
      refute_receive {:tool_ran, "write_file"}, 100
    end
  end

  describe "model_override" do
    test "is not applied: the request keeps the agent's model and a warning is logged once" do
      :persistent_term.erase({Nous.Plugins.Skills, :model_override_warned})
      on_exit(fn -> :persistent_term.erase({Nous.Plugins.Skills, :model_override_warned}) end)

      overriding = %{skill("pinned", nil) | model_override: "anthropic:claude-sonnet-4"}

      log = capture_log(fn -> assert {:ok, _} = run([overriding], "hello") end)
      assert log =~ "pinned set model_override, which Nous does not apply"
      assert_receive {:request_model, :openai, "test-model"}

      again = capture_log(fn -> assert {:ok, _} = run([overriding], "hello") end)
      refute again =~ "model_override"
    end
  end
end
