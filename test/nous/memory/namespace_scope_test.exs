defmodule Nous.Memory.NamespaceScopeTest do
  # Issue #96: `:namespace` is written on every memory entry but was never part
  # of the scope, so in a store shared by several namespaces recall, forget,
  # auto-inject and the auto-update reflection reached other namespaces'
  # memories. Driven through the paths the agent loop uses (ToolExecutor with a
  # RunContext, before_request/3, after_run/3 with a scripted reflection model)
  # against every memory store whose driver is available.
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.Memory.{Entry, Store, Tools}
  alias Nous.Plugins.Memory, as: MemoryPlugin

  # Scripted reflection model: replies with whatever JSON the test put in the
  # process dictionary (the reflection call runs in the caller's process).
  defmodule ScriptedReflection do
    @moduledoc false

    def request(_model, _messages, _settings),
      do: {:ok, Nous.Message.assistant(Process.get(:reflection_json, "[]"))}

    def request_stream(_model, _messages, _settings), do: {:error, :not_scripted}
    def count_tokens(_messages), do: 0
  end

  # Every entry carries the same agent/session/user, so only the namespace
  # tells the two tenants apart.
  @owner %{agent_id: "agent", session_id: "session", user_id: "alice"}

  # Config variants that must all stay inside "ns_a": namespace alone (which
  # used to build `:global`), and namespace combined with every
  # `:default_search_scope` mode, explicit `:global` included.
  @scoped_configs [
    %{namespace: "ns_a"}
    | for(
        mode <- [:agent, :user, :session, :global],
        do: Map.merge(@owner, %{namespace: "ns_a", default_search_scope: mode})
      )
  ]

  stores =
    [{Store.ETS, :ets}] ++
      if(Code.ensure_loaded?(Exqlite), do: [{Store.SQLite, :sqlite}], else: []) ++
      if Code.ensure_loaded?(Duckdbex), do: [{Store.DuckDB, :duckdb}], else: []

  for {store, tag} <- stores do
    describe "#{inspect(store)} shared by two namespaces" do
      @describetag tag
      @store store

      setup do
        Nous.ModelDispatcher.put_dispatcher(ScriptedReflection)
        {:ok, state} = @store.init([])

        {state, entries} =
          Enum.reduce(
            [
              fact_a: {"deploy target is fly", "ns_a"},
              fact_b: {"deploy target is fly", "ns_b"},
              note_a: {"scratch note", "ns_a"},
              note_b: {"scratch note", "ns_b"}
            ],
            {state, %{}},
            fn {key, {content, namespace}}, {state, acc} ->
              entry = Entry.new(Map.merge(@owner, %{content: content, namespace: namespace}))
              {:ok, state} = @store.store(state, entry)
              {state, Map.put(acc, key, entry)}
            end
          )

        %{base: %{store: @store, store_state: state}, state: state, entries: entries}
      end

      test "recall returns only the configured namespace's memories",
           %{base: base, entries: entries} do
        for scope_config <- @scoped_configs do
          ids = recall_ids(config(base, scope_config), "deploy target is fly")

          assert entries.fact_a.id in ids, "missing own memory for #{inspect(scope_config)}"

          assert ids -- [entries.fact_a.id, entries.note_a.id] == [],
                 "leaked another namespace for #{inspect(scope_config)}: #{inspect(ids)}"
        end
      end

      test "recall without a namespace stays global", %{base: base, entries: entries} do
        for scope_config <- [%{}, Map.put(@owner, :default_search_scope, :global)] do
          ids = recall_ids(config(base, scope_config), "deploy target is fly")

          assert entries.fact_a.id in ids
          assert entries.fact_b.id in ids
        end
      end

      test "forget can't delete another namespace's memory", %{
        base: base,
        state: state,
        entries: entries
      } do
        for scope_config <- @scoped_configs do
          result = run_tool("forget", config(base, scope_config), %{"id" => entries.fact_b.id})

          assert result.status == "not_found"

          assert {:ok, %{content: "deploy target is fly"}} =
                   @store.fetch(state, entries.fact_b.id)
        end

        own = run_tool("forget", config(base, %{namespace: "ns_a"}), %{"id" => entries.fact_a.id})
        assert own.status == "forgotten"
        assert {:error, :not_found} = @store.fetch(state, entries.fact_a.id)
      end

      test "auto-inject only injects the configured namespace's memories",
           %{base: base, entries: entries} do
        agent = Agent.new("openai:gpt-4", plugins: [MemoryPlugin])
        config = config(base, %{namespace: "ns_a", inject_min_score: 0.0, inject_limit: 10})

        ctx =
          agent
          |> MemoryPlugin.init(Context.new(deps: %{memory_config: config}))
          |> Context.add_message(Nous.Message.user("deploy target is fly"))

        {ctx, _tools} = MemoryPlugin.before_request(agent, ctx, [])

        injected =
          ctx.messages
          |> Enum.filter(&(&1.role == :system and &1.content =~ "<retrieved_memory"))
          |> Enum.map_join("\n", & &1.content)

        assert injected =~ entries.fact_a.id
        refute injected =~ entries.fact_b.id
        refute injected =~ entries.note_b.id
      end

      test "reflection update/forget skip another namespace's memories",
           %{base: base, state: state, entries: entries} do
        agent = Agent.new("openai:gpt-4", plugins: [MemoryPlugin])

        config =
          config(base, %{namespace: "ns_a", auto_update_memory: true, auto_update_every: 1})

        ctx = MemoryPlugin.init(agent, Context.new(deps: %{memory_config: config}))

        Process.put(
          :reflection_json,
          JSON.encode!([
            %{"action" => "update", "id" => entries.fact_b.id, "content" => "hijacked"},
            %{"action" => "forget", "id" => entries.note_b.id},
            %{"action" => "update", "id" => entries.fact_a.id, "content" => "updated"},
            %{"action" => "forget", "id" => entries.note_a.id}
          ])
        )

        MemoryPlugin.after_run(agent, %{output: "hi"}, ctx)

        assert {:ok, %{content: "deploy target is fly"}} = @store.fetch(state, entries.fact_b.id)
        assert {:ok, %{content: "scratch note"}} = @store.fetch(state, entries.note_b.id)
        assert {:ok, %{content: "updated"}} = @store.fetch(state, entries.fact_a.id)
        assert {:error, :not_found} = @store.fetch(state, entries.note_a.id)
      end

      # The unscoped single-tenant default: reflection lists, updates and
      # forgets across the whole store.
      test "reflection without a namespace stays global",
           %{base: base, state: state, entries: entries} do
        agent = Agent.new("openai:gpt-4", plugins: [MemoryPlugin])
        config = config(base, %{auto_update_memory: true, auto_update_every: 1})
        ctx = MemoryPlugin.init(agent, Context.new(deps: %{memory_config: config}))

        Process.put(
          :reflection_json,
          JSON.encode!([
            %{"action" => "update", "id" => entries.fact_b.id, "content" => "updated"},
            %{"action" => "forget", "id" => entries.note_a.id}
          ])
        )

        MemoryPlugin.after_run(agent, %{output: "hi"}, ctx)

        assert {:ok, %{content: "updated"}} = @store.fetch(state, entries.fact_b.id)
        assert {:error, :not_found} = @store.fetch(state, entries.note_a.id)
      end
    end
  end

  defp config(base, scope_config), do: Map.merge(base, scope_config)

  defp recall_ids(config, query) do
    result = run_tool("recall", config, %{"query" => query, "limit" => 10})
    assert result.status == "found"
    Enum.map(result.memories, & &1.id)
  end

  # As the agent loop runs a tool: Nous.ToolExecutor with a RunContext.
  defp run_tool(name, config, args) do
    tool = Enum.find(Tools.all_tools(), &(&1.name == name))
    ctx = Nous.RunContext.new(%{memory_config: config})
    {:ok, result, _update} = Nous.ToolExecutor.execute(tool, args, ctx)
    result
  end
end
