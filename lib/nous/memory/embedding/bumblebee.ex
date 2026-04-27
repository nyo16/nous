if Code.ensure_loaded?(Bumblebee) do
  defmodule Nous.Memory.Embedding.Bumblebee do
    @moduledoc """
    Local on-device embedding provider via Bumblebee + EXLA.

    Default model: Alibaba-NLP/gte-Qwen2-0.6B-instruct
    Zero API calls, fully offline.

    Requires optional deps: {:bumblebee, "~> 0.6"}, {:exla, "~> 0.9"}

    ## Architecture (M-7)

    Each model_name is owned by exactly one `ServingHolder` GenServer
    started under `ServingSupervisor` (a `DynamicSupervisor`) and
    registered by name in `Registry`. The serving lives in the GenServer's
    state — no `:persistent_term`, so no node-wide GC pause when a new
    model is loaded.

    Concurrent first-time callers race to start the holder; the
    `DynamicSupervisor.start_child/2` `{:error, {:already_started, pid}}`
    arm + Registry's `:unique` keys make this safe — only one model is
    loaded per `model_name`, ever.

    ## Options

      * `:model` - HuggingFace model repo (default: "Alibaba-NLP/gte-Qwen2-0.6B-instruct")
      * `:backend` - Nx backend module (default: EXLA.Backend if available)
      * `:load_timeout` - max ms to wait for a first-time model load (default: 600_000 = 10 minutes)
    """

    @behaviour Nous.Memory.Embedding

    alias Nous.Memory.Embedding.Bumblebee.{ServingHolder, ServingSupervisor}

    @default_model "Alibaba-NLP/gte-Qwen2-0.6B-instruct"
    @default_dimension 1024
    @default_load_timeout 600_000

    @impl true
    def embed(text, opts \\ []) do
      with {:ok, pid} <- get_or_start_holder(opts) do
        ServingHolder.run(pid, text, run_timeout(opts))
      end
    end

    @impl true
    def embed_batch(texts, opts \\ []) do
      with {:ok, pid} <- get_or_start_holder(opts) do
        ServingHolder.run_batch(pid, texts, run_timeout(opts))
      end
    end

    @impl true
    def dimension, do: @default_dimension

    @doc """
    Look up the ServingHolder for `opts[:model]`, starting one if needed.
    Returns `{:ok, pid}` or `{:error, reason}`.
    """
    @spec get_or_start_holder(keyword()) :: {:ok, pid()} | {:error, term()}
    def get_or_start_holder(opts) do
      model_name = opts[:model] || @default_model

      case Registry.lookup(Nous.Memory.Embedding.Bumblebee.Registry, model_name) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          start_holder(model_name, opts)
      end
    end

    defp start_holder(model_name, opts) do
      child_spec = {ServingHolder, {model_name, opts, load_timeout(opts)}}

      case DynamicSupervisor.start_child(ServingSupervisor, child_spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end

    defp load_timeout(opts), do: opts[:load_timeout] || @default_load_timeout
    defp run_timeout(opts), do: opts[:run_timeout] || 60_000
  end

  defmodule Nous.Memory.Embedding.Bumblebee.ServingSupervisor do
    @moduledoc false
    use DynamicSupervisor

    def start_link(opts) do
      DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      # Per-model holders are :transient so they restart on abnormal exit
      # but stay down on intentional shutdown. Tuned restart limits avoid
      # cascading the whole supervisor down if one model fails to load.
      DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 10)
    end
  end

  defmodule Nous.Memory.Embedding.Bumblebee.ServingHolder do
    @moduledoc false
    use GenServer, restart: :transient

    require Logger

    @registry Nous.Memory.Embedding.Bumblebee.Registry

    def child_spec({model_name, opts, load_timeout}) do
      %{
        id: {__MODULE__, model_name},
        start: {__MODULE__, :start_link, [{model_name, opts, load_timeout}]},
        restart: :transient,
        shutdown: 10_000,
        type: :worker
      }
    end

    def start_link({model_name, opts, load_timeout}) do
      GenServer.start_link(__MODULE__, {model_name, opts, load_timeout},
        name: {:via, Registry, {@registry, model_name}}
      )
    end

    @doc "Run the serving on a single text input."
    def run(pid, text, timeout) do
      GenServer.call(pid, {:run, text}, timeout)
    end

    @doc "Run the serving on a batch of text inputs."
    def run_batch(pid, texts, timeout) do
      GenServer.call(pid, {:run_batch, texts}, timeout)
    end

    @impl true
    def init({model_name, opts, _load_timeout}) do
      # Load eagerly in init — start_child blocks until init returns, so
      # the caller waits the full load time on first use. This is
      # intentional: no half-loaded states are visible to other callers.
      Logger.info("Bumblebee: loading model #{inspect(model_name)} (this may take a while)")

      backend =
        opts[:backend] ||
          if(Code.ensure_loaded?(EXLA.Backend), do: EXLA.Backend, else: {Nx.BinaryBackend, []})

      with {:ok, model_info} <- Bumblebee.load_model({:hf, model_name}, backend: backend),
           {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, model_name}) do
        serving =
          Bumblebee.Text.text_embedding(model_info, tokenizer,
            compile: [batch_size: 1, sequence_length: 512],
            defn_options: [
              compiler: if(Code.ensure_loaded?(EXLA), do: EXLA, else: Nx.Defn.Evaluator)
            ]
          )

        Logger.info("Bumblebee: model #{inspect(model_name)} loaded")
        {:ok, %{serving: serving, model_name: model_name}}
      else
        {:error, reason} ->
          Logger.error("Bumblebee: failed to load #{inspect(model_name)}: #{inspect(reason)}")
          {:stop, {:load_failed, reason}}
      end
    rescue
      e ->
        Logger.error("Bumblebee: load raised: #{Exception.message(e)}")
        {:stop, {:load_raised, Exception.message(e)}}
    end

    @impl true
    def handle_call({:run, text}, _from, %{serving: serving} = state) do
      try do
        result = Nx.Serving.run(serving, text)
        embedding = result.embedding |> Nx.to_flat_list()
        {:reply, {:ok, embedding}, state}
      rescue
        e -> {:reply, {:error, Exception.message(e)}, state}
      end
    end

    @impl true
    def handle_call({:run_batch, texts}, _from, %{serving: serving} = state) do
      try do
        results = Nx.Serving.run(serving, texts)

        embeddings =
          results.embedding
          |> Nx.to_batched(1)
          |> Enum.map(&Nx.to_flat_list/1)

        {:reply, {:ok, embeddings}, state}
      rescue
        e -> {:reply, {:error, Exception.message(e)}, state}
      end
    end
  end
else
  defmodule Nous.Memory.Embedding.Bumblebee do
    @moduledoc """
    Local on-device embedding provider via Bumblebee + EXLA.

    **Not available** - add `{:bumblebee, "~> 0.6"}` and `{:exla, "~> 0.9"}` to your deps.
    """

    @behaviour Nous.Memory.Embedding

    @impl true
    def embed(_text, _opts \\ []) do
      {:error,
       "Bumblebee is not available. Add {:bumblebee, \"~> 0.6\"} and {:exla, \"~> 0.9\"} to your mix.exs deps."}
    end

    @impl true
    def embed_batch(_texts, _opts \\ []) do
      {:error,
       "Bumblebee is not available. Add {:bumblebee, \"~> 0.6\"} and {:exla, \"~> 0.9\"} to your mix.exs deps."}
    end

    @impl true
    def dimension, do: 1024
  end
end
