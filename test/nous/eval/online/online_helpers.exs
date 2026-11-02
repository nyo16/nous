defmodule Nous.Eval.OnlineHelpers do
  @moduledoc false
  # Shared by the online-eval tests (loaded with `Code.require_file/2`).
  #
  # The model stub is installed in the application environment, not per
  # process: online scorers and redactors run in the instance's own tasks,
  # which do not descend from the test process. Every online test module is
  # therefore `async: false`.

  import ExUnit.Assertions

  alias Nous.{Message, Usage}
  alias Nous.Eval.Online

  @canary "CANARY-7f3a91c2e4b8d605"

  def canary, do: @canary

  defmodule Stub do
    @moduledoc false
    # Prompt keywords: GATE blocks until the test sends `:go`; FAIL returns a
    # provider error quoting the canary; TOOL asks for `lookup`; PARALLEL
    # asks for two lookups at once; SUB asks for `delegate`. A judge request
    # (system prompt naming a verdict) is answered badly first, then with a
    # verdict whose critique quotes the canary, so every judge call costs
    # exactly its two-request worst case.

    alias Nous.{Message, Usage}

    @canary "CANARY-7f3a91c2e4b8d605"

    def request(_model, messages, _settings) do
      system = Enum.find_value(messages, "", &(&1.role == :system && Message.extract_text(&1)))
      last = messages |> Enum.reject(&(&1.role == :system)) |> List.last()
      text = (last && Message.extract_text(last)) || ""

      cond do
        system =~ "verdict" ->
          judge(messages)

        last.role == :tool ->
          reply("Answer: #{text} #{@canary}")

        text =~ "GATE" ->
          gate()

        text =~ "FAIL" ->
          {:error, RuntimeError.exception("provider rejected #{@canary}")}

        text =~ "PARALLEL" ->
          calls([{"lookup", %{"query" => @canary}}, {"lookup", %{"query" => "b"}}])

        text =~ "TOOL" ->
          calls([{"lookup", %{"query" => "find #{@canary}"}}])

        text =~ "SUB" ->
          calls([{"delegate", %{"task" => "inner #{@canary}"}}])

        true ->
          reply("echo: #{text}")
      end
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 10

    defp gate do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        pid when is_pid(pid) -> send(pid, {:gated, self()})
        _ -> :ok
      end

      receive do
        :go -> reply("released")
      after
        10_000 -> reply("gate timeout")
      end
    end

    defp judge(messages) do
      if Enum.any?(messages, &(&1.role == :assistant)) do
        reply(
          JSON.encode!(%{"verdict" => "pass", "critique" => "quotes #{@canary}"}),
          %Usage{requests: 1, input_tokens: 16_000, output_tokens: 2_000, total_tokens: 18_000}
        )
      else
        reply("not json at all", %Usage{
          requests: 1,
          input_tokens: 16_000,
          output_tokens: 2_000,
          total_tokens: 18_000
        })
      end
    end

    def reply(
          text,
          usage \\ %Usage{requests: 1, input_tokens: 7, output_tokens: 3, total_tokens: 10}
        ),
        do: {:ok, Message.assistant(text, metadata: %{usage: usage, finish_reason: "stop"})}

    defp calls(calls) do
      tool_calls =
        for {name, args} <- calls,
            do: %{id: "call_#{System.unique_integer([:positive])}", name: name, arguments: args}

      {:ok,
       Message.assistant("",
         tool_calls: tool_calls,
         metadata: %{
           usage: %Usage{requests: 1, input_tokens: 7, output_tokens: 3, total_tokens: 10},
           finish_reason: "tool_calls"
         }
       )}
    end
  end

  defmodule Tools do
    @moduledoc false

    @canary "CANARY-7f3a91c2e4b8d605"

    def lookup(_ctx, %{"query" => query}), do: "result for #{query}: #{@canary}"

    def delegate(_ctx, %{"task" => task}) do
      {:ok, result} = Nous.run(Nous.new("openai:gpt-4o-mini", name: "sub_agent"), task)
      "sub said: " <> result.output
    end

    def all do
      [
        Nous.Tool.from_function(&__MODULE__.lookup/2,
          name: "lookup",
          description: "Look something up",
          parameters: %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          }
        ),
        Nous.Tool.from_function(&__MODULE__.delegate/2,
          name: "delegate",
          description: "Delegate to a sub-agent",
          parameters: %{
            "type" => "object",
            "properties" => %{"task" => %{"type" => "string"}},
            "required" => ["task"]
          }
        )
      ]
    end
  end

  def install_stub(owner \\ self()) do
    previous = Application.get_env(:nous, :model_dispatcher)
    Application.put_env(:nous, :model_dispatcher, Stub)
    :persistent_term.put({Stub, :owner}, owner)

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({Stub, :owner})

      if previous,
        do: Application.put_env(:nous, :model_dispatcher, previous),
        else: Application.delete_env(:nous, :model_dispatcher)
    end)
  end

  def agent(name \\ "support_bot"),
    do: Nous.new("openai:gpt-4o-mini", name: name, instructions: "Help.", tools: Tools.all())

  def run!(prompt, opts \\ []) do
    Nous.run(Keyword.get(opts, :agent, agent()), prompt, Keyword.delete(opts, :agent))
  end

  @doc "Base options for a test instance writing to `root`."
  def base_opts(root, overrides \\ []) do
    Keyword.merge(
      [
        sample_rate: 1.0,
        redact: :drop_content,
        store: {Nous.Eval.Store.File, root: root},
        retention: [max_age: {7, :day}],
        window_ms: 600_000,
        sweep_interval: 600_000
      ],
      overrides
    )
  end

  def start_online!(opts) do
    name = Keyword.get(opts, :name, Online)
    ExUnit.Callbacks.start_supervised!({Online, opts}, id: name)
  end

  def store!(root) do
    {:ok, state} = Nous.Eval.Store.File.init(root: root)
    {Nous.Eval.Store.File, state}
  end

  def samples!(root, opts \\ []) do
    {:ok, entries} = Online.list(store!(root), opts)
    entries
  end

  @doc "Every byte under `root`, for leak checks."
  def all_bytes(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join("\n", &File.read!/1)
  end

  @doc "Collects every `[:nous, :eval, :online, ...]` event into the test mailbox."
  def attach_online_events do
    id = {__MODULE__, make_ref()}
    events = Enum.filter(Nous.Telemetry.events(), &match?([:nous, :eval, :online | _], &1))

    :telemetry.attach_many(id, events, &__MODULE__.forward_event/4, self())

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  @doc false
  def forward_event(name, measurements, metadata, pid),
    do: send(pid, {:online_event, name, measurements, metadata})

  @doc "The window measurements after a tick (`Nous.Eval.Online.tick/1`)."
  def window!(name \\ Online) do
    :ok = Online.tick(name)
    assert_receive {:online_event, [:nous, :eval, :online, :window], counts, _meta}, 1_000
    counts
  end

  def flush_online_events do
    receive do
      {:online_event, _, _, _} -> flush_online_events()
    after
      0 -> :ok
    end
  end

  def handler_attached?(name \\ Online) do
    [:nous, :agent, :run, :start]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == {Online, name}))
  end

  def text(%Message{} = message), do: Message.extract_text(message)
end
