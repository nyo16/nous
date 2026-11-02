defmodule Nous.Eval.Guard.Deterministic do
  @moduledoc """
  Decision-table checks for the deterministic guards: `Nous.Permissions`,
  `Nous.Plugins.LoopGuard` and hooks. No statistics: every row must match,
  and any mismatch fails.

  Rows are `nous.guard_case/1` cases of kind `"permission"`, `"loop_guard"`
  or `"hook"` (`Nous.Eval.Guard.Case`). Policies and hooks are code, so a row
  names a **fixture** (`"guard"`) the caller registers in Elixir; the case
  data never carries code.

      fixtures = %{
        permission: %{"default" => Nous.Permissions.default_policy()},
        loop_guard: %{"default" => %{}},
        hook: %{"no_rm_rf" => [Nous.Hook.new(:pre_tool_use, handler: &MyHooks.no_rm_rf/2)]}
      }

      {:ok, ds} = Nous.Eval.Guard.Dataset.load("test/fixtures/guard/deterministic")
      :ok = Nous.Eval.Guard.Deterministic.check(ds.cases, fixtures)

  ## Rows

    * `permission` - input `{"tool_name": string, "category": "read" |
      "write" | "execute" | "communicate" | "search" | null}`; expected
      `{"blocked": bool, "requires_approval": bool}` from
      `Nous.Permissions.blocked?/2` and `requires_approval?/3`. Fixture: a
      `%Nous.Permissions.Policy{}`.
    * `loop_guard` - input `{"messages": [message]}`, each `{"role": "user" |
      "assistant" | "tool" | "system", "content"?: string, "tool_calls"?:
      [{"name": string, "arguments": object | string}], "loop_guard"?:
      integer}` (`loop_guard` marks an advisory the plugin already
      injected); expected `{"advisory_threshold": integer | null}`: the
      threshold of the advisory `before_request/3` appends to that
      transcript, or none. Fixture: a `:loop_guard_config` map.
    * `hook` - input `{"event": string, "payload": object}` (payload keys
      `tool_name`, `tool_id`, `arguments`, `result`, `content`,
      `tool_calls`, `response`); expected `{"result": "allow" | "deny" |
      "modify"}` plus optional `"changes"` (the `{:modify, changes}` map,
      string keys) from `Nous.Hook.Runner.run/3` over a
      `Nous.Hook.Registry` of the fixture's hooks (so matchers and priorities
      apply as in a run). Fixture: a list of
      `%Nous.Hook{}`.
  """

  alias Nous.Agent.Context
  alias Nous.Eval.Guard.Case
  alias Nous.{Hook, Message, Permissions}
  alias Nous.Plugins.LoopGuard

  @categories %{
    "read" => :read,
    "write" => :write,
    "execute" => :execute,
    "communicate" => :communicate,
    "search" => :search
  }
  @events %{
    "pre_tool_use" => :pre_tool_use,
    "post_tool_use" => :post_tool_use,
    "pre_request" => :pre_request,
    "post_response" => :post_response,
    "session_start" => :session_start,
    "session_end" => :session_end
  }
  @payload_keys %{
    "tool_name" => :tool_name,
    "tool_id" => :tool_id,
    "arguments" => :arguments,
    "result" => :result,
    "content" => :content,
    "tool_calls" => :tool_calls,
    "response" => :response
  }
  @roles %{"user" => :user, "assistant" => :assistant, "tool" => :tool, "system" => :system}

  @type fixtures :: %{
          optional(:permission) => %{String.t() => Permissions.Policy.t()},
          optional(:loop_guard) => %{String.t() => map()},
          optional(:hook) => %{String.t() => [Hook.t()]}
        }

  @type mismatch :: %{id: String.t(), expected: map(), actual: map() | {:error, term()}}

  @doc """
  Runs every deterministic row of `cases` (classifier cases are ignored)
  against `fixtures`. Returns `:ok`, or `{:error, mismatches}` listing every
  row whose actual output differs, or that names an unregistered fixture
  or holds malformed input (both fail).
  """
  @spec check([Case.t()], fixtures()) :: :ok | {:error, [mismatch()]}
  def check(cases, fixtures) do
    mismatches =
      for %Case{kind: kind} = c <- cases,
          kind != :classifier,
          actual = run(c, fixtures),
          actual != c.expected,
          do: %{id: c.id, expected: c.expected, actual: actual}

    if mismatches == [], do: :ok, else: {:error, mismatches}
  end

  @doc """
  The actual output of one deterministic row, in the shape of its
  `expected`, or `{:error, reason}`.
  """
  @spec run(Case.t(), fixtures()) :: map() | {:error, term()}
  def run(%Case{kind: kind, guard: name} = c, fixtures) do
    case fixtures |> Map.get(kind, %{}) |> Map.fetch(name) do
      {:ok, fixture} -> safe(fn -> run_kind(kind, fixture, c) end)
      :error -> {:error, {:unknown_fixture, kind, name}}
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_kind(:permission, %Permissions.Policy{} = policy, %Case{input: input}) do
    with {:ok, name} <- string(input["tool_name"], "tool_name"),
         {:ok, category} <- category(input["category"]) do
      %{
        "blocked" => Permissions.blocked?(policy, name),
        "requires_approval" => Permissions.requires_approval?(policy, name, category)
      }
    end
  end

  defp run_kind(:loop_guard, config, %Case{input: %{"messages" => messages}})
       when is_list(messages) do
    with {:ok, messages} <- messages(messages) do
      agent = %Nous.Agent{
        model: %Nous.Model{provider: :openai, model: "decision-table"},
        name: "decision-table"
      }

      ctx = %Context{messages: messages, deps: %{loop_guard_config: config}}
      {after_ctx, _tools} = LoopGuard.before_request(agent, ctx, [])

      added = Enum.drop(after_ctx.messages, length(messages))
      %{"advisory_threshold" => Enum.find_value(added, &Message.get_metadata(&1, :loop_guard))}
    end
  end

  defp run_kind(:hook, hooks, %Case{
         input: %{"event" => event, "payload" => %{} = payload},
         expected: expected
       })
       when is_list(hooks) do
    with {:ok, event} <- lookup(@events, event, "event"),
         {:ok, payload} <- payload(payload) do
      hooks
      |> Hook.Registry.from_hooks()
      |> Hook.Runner.run(event, payload)
      |> hook_result(Map.has_key?(expected, "changes"))
    end
  end

  defp run_kind(kind, _fixture, _case), do: {:error, {:malformed_row, kind}}

  defp hook_result(:allow, _changes?), do: %{"result" => "allow"}
  defp hook_result(:deny, _changes?), do: %{"result" => "deny"}
  defp hook_result({:deny, _reason}, _changes?), do: %{"result" => "deny"}
  defp hook_result({:modify, _changes}, false), do: %{"result" => "modify"}

  defp hook_result({:modify, changes}, true),
    do: %{"result" => "modify", "changes" => stringify(changes)}

  defp hook_result({:error, reason}, _changes?),
    do: %{"result" => "error", "error" => inspect(reason)}

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp payload(payload) do
    Enum.reduce_while(payload, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case lookup(@payload_keys, key, "payload key") do
        {:ok, atom} -> {:cont, {:ok, Map.put(acc, atom, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp messages(list) do
    Enum.reduce_while(list, {:ok, []}, fn m, {:ok, acc} ->
      case message(m) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp message(%{"role" => role} = m) do
    with {:ok, role} <- lookup(@roles, role, "role") do
      content = Map.get(m, "content", "")
      metadata = if m["loop_guard"], do: %{loop_guard: m["loop_guard"]}, else: %{}

      calls =
        m
        |> Map.get("tool_calls", [])
        |> Enum.with_index()
        |> Enum.map(fn {call, i} ->
          %{id: "call_#{i}", name: call["name"], arguments: call["arguments"]}
        end)

      {:ok, build(role, content, calls, metadata)}
    end
  end

  defp message(other), do: {:error, {:malformed_message, other}}

  defp build(:user, content, _calls, metadata), do: Message.user(content, metadata: metadata)
  defp build(:system, content, _calls, _metadata), do: Message.system(content)
  defp build(:tool, content, _calls, _metadata), do: Message.tool("call_0", content)
  defp build(:assistant, content, [], _metadata), do: Message.assistant(content)

  defp build(:assistant, content, calls, _metadata),
    do: Message.assistant(content, tool_calls: calls)

  defp category(nil), do: {:ok, nil}
  defp category(value), do: lookup(@categories, value, "category")

  defp string(value, _key) when is_binary(value), do: {:ok, value}
  defp string(value, key), do: {:error, {:malformed, key, value}}

  defp lookup(table, value, key) do
    case Map.fetch(table, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown, key, value}}
    end
  end
end
