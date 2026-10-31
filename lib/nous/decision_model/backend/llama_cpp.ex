if Code.ensure_loaded?(LlamaCppEx.Decision) do
  defmodule Nous.DecisionModel.Backend.LlamaCpp do
    @moduledoc """
    In-process decision backend on `LlamaCppEx.Decision` (llama.cpp's
    `/v1/systemone`, ported into the NIF): Clef / Clef-Flash, OpenJev, Laya and
    the other decision GGUFs, with no server.

    Requires the optional dep `{:llama_cpp_ex, "~> 0.8.63"}`.

    ## The process owns the model

    A `%LlamaCppEx.Decision{}` drives one llama.cpp context and is not safe for
    concurrent use, so each loaded model lives in its own process, which
    serialises the calls. Start it under your supervision tree:

        children = [
          {Nous.DecisionModel.Backend.LlamaCpp,
           name: :clef, source: {:path, "/models/Clef-Flash-Q8_0.gguf"}}
        ]

        dm = Nous.DecisionModel.parse("llamacpp:clef")
        {:ok, result} = Nous.DecisionModel.decide(dm, state, questions)

    `"llamacpp:<name>"` resolves `<name>` with `String.to_existing_atom/1`
    and then only to a process this module started: each process registers
    its name in a registry this module owns, and a name that is not there
    (any other registered process included) is `:unavailable`, never called.
    Pass `server:` (a pid or any `t:GenServer.server/0`) to
    `Nous.DecisionModel.new/2` or `parse/2` for another name form; it is
    checked the same way and must be a process of this module on this node.

    ## Start options

      * `:name` - required; the registered name.
      * `:source` - required; `{:path, path}`, or `{:hub, repo, file}` to
        download from Hugging Face through `LlamaCppEx.Hub` (only when given
        explicitly).
      * `:n_batch` - tokens per batch. Clef evaluates the whole prompt (state
        plus questions) in one batch, so this caps the request size. Default
        `4096`, or `:n_ctx` when only that is given.
      * `:n_ctx` - context size. Default: `:n_batch`.
      * `:n_gpu_layers` - default `-1` (all).
      * `:decision_opts` - extra `LlamaCppEx.Decision.new/2` tuning options
        (`:n_threads`, `:flash_attn`, ...).
      * `:shutdown` - the child spec's shutdown, in ms: how long the
        supervisor waits before escalating to `:kill`. Default `30_000`. The
        process does not trap exits, so it stops as soon as an in-flight
        decode returns; the model is freed with the process either way.

    `:n_ctx` and `:n_batch` are capped at 32,768: above that, the macOS GPU
    watchdog kills the single command buffer and poisons the context. A
    larger value raises `ArgumentError` at start.

    The model loads in `handle_continue/2`, so start-up does not block the
    supervisor; calls made while it loads wait for it. The loaded model is
    published in the process's registry entry, which goes away with the
    process however it exits, so the model's memory is freed with it.

    ## Special tokens

    Before tokenizing, every `<...>`, `[...]` or `|||...|||` sequence in the
    state that the loaded vocabulary parses as one token (control and
    user-defined tokens, such as Clef's `<tts_pad>` and `</think>`) is broken
    with `Nous.DecisionModel.Defang.defang_tokens/2`, on top of the generic
    `Nous.DecisionModel.Defang` pass. `count_tokens/2` counts the same text.

    ## Decide options

      * `:timeout` - how long to wait for the serialised call, in ms. Default
        `30_000`. Calls queue behind each other: one Clef-Flash check takes
        ~0.5–1 s on an M1 Max. A request whose timeout has passed, or whose
        caller has exited, by the time the process reaches it is not decoded.

    ## Errors

      * a prompt that does not fit `n_batch` / `n_ctx` → `:oversize`. Raise
        `n_batch`, or chunk the state (`max_state_tokens/1` is the budget).
      * `"decision decode failed with code: -3"` (macOS GPU watchdog) and
        other negative decode codes → `:backend_dead`; the context is
        recreated before the next call. If recreating it fails, that call
        gets `:backend_dead` and the process exits, so its supervisor
        restarts it with a fresh model.
      * the call timing out → `:timeout`; the process not running, or the
        name not belonging to this module → `:unavailable`.
    """

    use GenServer

    @behaviour Nous.DecisionModel.Backend

    require Logger

    alias LlamaCppEx.Decision
    alias Nous.DecisionModel
    alias Nous.DecisionModel.{Backend, Defang, Question, Result, SystemOneWire}

    # Started by Nous.Application. Each process registers its name here with
    # %{n_batch: _, model: _} as the value: the entry is the only way a caller
    # resolves a process, and it disappears with the process (any exit,
    # `:kill` included), taking its reference to the model with it.
    @registry Nous.DecisionModel.Registry

    @default_n_batch 4096
    @max_n 32_768
    @default_call_timeout 30_000
    @default_shutdown 30_000

    @oversize ~r/must be evaluated in one batch|does not fit in the context|do not fit in the context|must fit in one batch|too large to process/
    @dead ~r/decision decode failed with code: -\d+/

    # --- Backend callbacks ---

    @impl Backend
    def decide(%DecisionModel{} = dm, state, questions, call_opts) do
      timeout =
        Keyword.get(call_opts, :timeout) || Keyword.get(dm.opts, :timeout, @default_call_timeout)

      with {:ok, pid, _info} <- lookup(dm) do
        try do
          case GenServer.call(pid, {:decide, state, questions, deadline(timeout)}, timeout) do
            {:ok, raw} -> build_result(dm, raw, questions)
            {:error, _} = error -> error
          end
        catch
          :exit, {:timeout, _} ->
            {:error,
             Backend.error(__MODULE__, :timeout, "decision call timed out after #{timeout} ms")}

          :exit, {:noproc, _} ->
            {:error, unavailable(label(dm))}

          :exit, reason ->
            {:error,
             Backend.error(__MODULE__, :backend_dead, "decision process exited", details: reason)}
        end
      end
    end

    defp deadline(:infinity), do: :infinity
    defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

    @doc """
    The request budget: the process's `n_batch` (Clef evaluates state plus
    questions in one batch).

    Exits if the process is not running.
    """
    @impl Backend
    def max_state_tokens(%DecisionModel{} = dm) do
      {_pid, %{n_batch: n_batch}} = lookup!(dm)
      n_batch
    end

    @doc """
    Exact token count of `text` with the model's tokenizer
    (`add_special: false, parse_special: false`), after breaking the
    vocabulary's special tokens (see "Special tokens").

    Tokenizes in the caller once the model is loaded; before that it waits
    for the load. Exits if the process is not running.
    """
    @impl Backend
    def count_tokens(%DecisionModel{} = dm, text) when is_binary(text) do
      case lookup!(dm) do
        {_pid, %{model: %LlamaCppEx.Model{} = model}} -> token_count(model, text)
        {pid, _} -> GenServer.call(pid, {:count_tokens, text}, @default_call_timeout)
      end
    end

    defp token_count(model, text) do
      {:ok, tokens} =
        LlamaCppEx.Tokenizer.encode(model, defang_vocab(model, text),
          add_special: false,
          parse_special: false
        )

      length(tokens)
    end

    # Breaks every delimited sequence the vocabulary parses as one token:
    # control tokens (`<|im_start|>`, `<tts_pad>`) and user-defined ones
    # (`<think>`, which llama.cpp matches even without special parsing).
    # Normal BPE tokens never span such a sequence, since the pre-tokenizer
    # splits `<word>` into `<word` and `>`.
    defp defang_vocab(model, text) do
      Defang.defang_tokens(text, fn candidate ->
        match?(
          {:ok, [_]},
          LlamaCppEx.Tokenizer.encode(model, candidate, add_special: false, parse_special: true)
        )
      end)
    end

    @impl Backend
    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.get(opts, :name)},
        start: {__MODULE__, :start_link, [opts]},
        shutdown: Keyword.get(opts, :shutdown, @default_shutdown)
      }
    end

    @doc """
    Starts the process that owns one decision model. See "Start options".
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      config = config!(opts)
      GenServer.start_link(__MODULE__, config, name: config.name)
    end

    # --- GenServer ---

    @impl GenServer
    def init(config) do
      case Registry.register(@registry, config.name, %{n_batch: config.n_batch, model: nil}) do
        {:ok, _owner} ->
          {:ok, Map.merge(config, %{model: nil, decision: nil}), {:continue, :load}}

        {:error, reason} ->
          {:stop, reason}
      end
    end

    @impl GenServer
    def handle_continue(:load, state) do
      :ok = LlamaCppEx.init()

      with {:ok, model} <- load(state.source, state.n_gpu_layers),
           {:ok, decision} <- new_decision(model, state) do
        {_new, _old} = Registry.update_value(@registry, state.name, &%{&1 | model: model})
        {:noreply, %{state | model: model, decision: decision}}
      else
        {:error, reason} ->
          Logger.error("Nous.DecisionModel.Backend.LlamaCpp failed to load: #{inspect(reason)}")
          {:stop, {:load_failed, reason}, state}
      end
    end

    @impl GenServer
    def handle_call({:decide, decision_state, questions, deadline}, {caller, _tag}, state) do
      if expired?(deadline, caller) do
        {:reply,
         {:error,
          Backend.error(__MODULE__, :timeout, "the request expired before it was decoded")},
         state}
      else
        decide_now(state, decision_state, questions)
      end
    end

    def handle_call({:count_tokens, text}, _from, %{model: model} = state) do
      {:reply, token_count(model, text), state}
    end

    # A queued request whose caller already gave up (its timeout passed, or it
    # exited) gets no decode: the reply would go nowhere, and the work would
    # only push the live requests behind it past their own deadlines.
    defp expired?(deadline, caller) do
      (deadline != :infinity and System.monotonic_time(:millisecond) >= deadline) or
        (node(caller) == node() and not Process.alive?(caller))
    end

    defp decide_now(state, decision_state, questions) do
      case ensure_decision(state) do
        {:ok, state} ->
          decision_state = Defang.defang_term(decision_state, &defang_vocab(state.model, &1))
          {reply, state} = run_decide(state, decision_state, questions)
          {:reply, reply, state}

        {:error, reason} ->
          error =
            Backend.error(__MODULE__, :backend_dead, "could not recreate the decision context",
              details: reason
            )

          # Exit so the supervisor restarts the process with a fresh model,
          # rather than answering :backend_dead forever.
          {:stop, {:context_recreate_failed, reason}, {:error, error}, state}
      end
    end

    defp run_decide(state, decision_state, questions) do
      case Decision.decide(state.decision, decision_state, to_llama_questions(questions)) do
        {:ok, raw} ->
          {{:ok, raw}, state}

        {:error, message} ->
          {map_decide_error(message), state_after_error(state, message)}
      end
    rescue
      e in ArgumentError ->
        {{:error, Backend.error(__MODULE__, :invalid_response, Exception.message(e))}, state}
    end

    defp map_decide_error(message) do
      reason =
        cond do
          Regex.match?(@oversize, message) -> :oversize
          Regex.match?(@dead, message) -> :backend_dead
          true -> :invalid_response
        end

      {:error, Backend.error(__MODULE__, reason, message, details: message)}
    end

    # A negative decode code (the macOS GPU watchdog's -3 among them) leaves
    # the context unusable: drop it so the next call builds a fresh one.
    defp state_after_error(state, message) do
      if Regex.match?(@dead, message) do
        Logger.warning(
          "Nous.DecisionModel.Backend.LlamaCpp: #{message}; recreating the decision context"
        )

        %{state | decision: nil}
      else
        state
      end
    end

    # The context that failed with a negative decode code is unusable; build a
    # fresh one before the next call. The dead one is garbage by now (only the
    # previous state held it): collect it first so its KV cache is freed
    # before a second one is allocated.
    defp ensure_decision(%{decision: nil, model: model} = state) do
      :erlang.garbage_collect()

      case new_decision(model, state) do
        {:ok, decision} -> {:ok, %{state | decision: decision}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp ensure_decision(state), do: {:ok, state}

    defp new_decision(model, state) do
      Decision.new(model, [n_ctx: state.n_ctx, n_batch: state.n_batch] ++ state.decision_opts)
    end

    defp load({:path, path}, n_gpu_layers) do
      LlamaCppEx.load_model(Path.expand(path), n_gpu_layers: n_gpu_layers)
    end

    defp load({:hub, repo, file}, n_gpu_layers) do
      LlamaCppEx.load_model_from_hub(repo, file, n_gpu_layers: n_gpu_layers)
    end

    # --- translation ---

    # An ordered keyword-style list with string ids and option keys, so
    # llama_cpp_ex keeps the order and hands back strings, which are mapped
    # back through the declared keys (never atomised).
    defp to_llama_questions(questions) do
      Enum.map(questions, fn %Question{} = question ->
        fields =
          [type: question.type]
          |> then(
            &if(question.instructions, do: &1 ++ [instructions: question.instructions], else: &1)
          )
          |> then(
            &if(question.criteria, do: &1 ++ [criteria: llama_criteria(question)], else: &1)
          )

        {Question.key_string(question.id), fields}
      end)
    end

    defp llama_criteria(%Question{type: :score, criteria: levels}), do: levels

    defp llama_criteria(%Question{criteria: pairs}) do
      Enum.map(pairs, fn {key, desc} -> {Question.key_string(key), desc} end)
    end

    defp build_result(dm, %{answers: answers, usage: usage}, questions) do
      with {:ok, decoded} <-
             SystemOneWire.decode_answers(wire_answers(answers), questions, __MODULE__) do
        {:ok,
         %Result{
           answers: decoded,
           usage: %{
             input_tokens: usage[:input_tokens],
             output_tokens: usage[:output_tokens]
           },
           backend: __MODULE__,
           model: dm.model
         }}
      end
    end

    # llama_cpp_ex decodes answers to atom-keyed maps; put them back in the
    # System One JSON shape the shared decoder reads.
    defp wire_answers(answers) do
      Map.new(answers, fn {id, answer} ->
        {to_string(id),
         Map.new(answer, fn
           {:type, type} ->
             {"type", Atom.to_string(type)}

           {:probabilities, probs} ->
             {"probabilities", Map.new(probs, fn {k, p} -> {to_string(k), p} end)}

           {:choice, choice} ->
             {"choice", to_string(choice)}

           {field, value} ->
             {Atom.to_string(field), value}
         end)}
      end)
    end

    # --- config / lookup ---

    defp config!(opts) do
      name = Keyword.get(opts, :name) || raise ArgumentError, ":name is required"
      source = Keyword.get(opts, :source) || raise ArgumentError, ":source is required"

      unless match?({:path, p} when is_binary(p), source) or
               match?({:hub, r, f} when is_binary(r) and is_binary(f), source) do
        raise ArgumentError,
              ":source must be {:path, path} or {:hub, repo, file}, got: #{inspect(source)}"
      end

      n_batch = Keyword.get(opts, :n_batch) || Keyword.get(opts, :n_ctx) || @default_n_batch
      n_ctx = Keyword.get(opts, :n_ctx) || n_batch
      check_size!(:n_batch, n_batch)
      check_size!(:n_ctx, n_ctx)

      if n_batch > n_ctx do
        raise ArgumentError, ":n_batch (#{n_batch}) must not exceed :n_ctx (#{n_ctx})"
      end

      %{
        name: name,
        source: source,
        n_batch: n_batch,
        n_ctx: n_ctx,
        n_gpu_layers: Keyword.get(opts, :n_gpu_layers, -1),
        decision_opts: Keyword.get(opts, :decision_opts, [])
      }
    end

    defp check_size!(_key, n) when is_integer(n) and n > 0 and n <= @max_n, do: :ok

    defp check_size!(key, n) do
      raise ArgumentError,
            "#{inspect(key)} must be a positive integer of at most #{@max_n} " <>
              "(the macOS GPU watchdog kills larger batches), got: #{inspect(n)}"
    end

    # Resolves only processes this module started (they are in @registry);
    # any other process, whatever its name, is :unavailable and never called.
    defp lookup(%DecisionModel{opts: opts, model: model} = dm) do
      case Keyword.fetch(opts, :server) do
        {:ok, server} ->
          lookup_pid(GenServer.whereis(server), dm)

        :error when is_binary(model) ->
          lookup_name(existing_atom(model), dm)

        :error ->
          {:error, Backend.error(__MODULE__, :unavailable, "no decision process name given")}
      end
    end

    # The registry drops an entry asynchronously after its process exits;
    # the liveness check closes that window, so a dead process's model is
    # never used.
    defp lookup_name({:ok, name}, dm) do
      case Registry.lookup(@registry, name) do
        [{pid, info}] ->
          if Process.alive?(pid), do: {:ok, pid, info}, else: lookup_name(:error, dm)

        [] ->
          lookup_name(:error, dm)
      end
    end

    defp lookup_name(:error, dm), do: {:error, unavailable(label(dm))}

    defp lookup_pid(pid, dm) when is_pid(pid) and node(pid) == node() do
      case Registry.keys(@registry, pid) do
        [name] -> lookup_name({:ok, name}, dm)
        [] -> {:error, unavailable(label(dm))}
      end
    end

    defp lookup_pid(_other, dm), do: {:error, unavailable(label(dm))}

    defp lookup!(dm) do
      case lookup(dm) do
        {:ok, pid, info} -> {pid, info}
        {:error, error} -> exit({:noproc, error.message})
      end
    end

    defp existing_atom(string) do
      {:ok, String.to_existing_atom(string)}
    rescue
      ArgumentError -> :error
    end

    defp label(%DecisionModel{opts: opts, model: model}), do: Keyword.get(opts, :server, model)

    defp unavailable(server) do
      Backend.error(
        __MODULE__,
        :unavailable,
        "no #{inspect(__MODULE__)} process running as #{inspect(server)}",
        retryable?: false
      )
    end
  end
else
  defmodule Nous.DecisionModel.Backend.LlamaCpp do
    @moduledoc """
    In-process decision backend on `LlamaCppEx.Decision`.

    **Not available** - add `{:llama_cpp_ex, "~> 0.8.63"}` to your mix.exs deps.
    """

    @behaviour Nous.DecisionModel.Backend

    @not_available "LlamaCppEx.Decision is not available. Add {:llama_cpp_ex, \"~> 0.8.63\"} to your mix.exs deps."

    @impl true
    def decide(_dm, _state, _questions, _opts) do
      {:error,
       Nous.DecisionModel.Backend.error(__MODULE__, :unavailable, @not_available,
         details: :not_available
       )}
    end

    @impl true
    def child_spec(opts) do
      %{id: {__MODULE__, Keyword.get(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}
    end

    @doc false
    def start_link(_opts), do: {:error, @not_available}
  end
end
