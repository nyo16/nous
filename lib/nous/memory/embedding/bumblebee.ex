if Code.ensure_loaded?(Bumblebee) do
  defmodule Nous.Memory.Embedding.Bumblebee do
    @moduledoc """
    Local on-device embedding provider via Bumblebee + EXLA.

    Default model: Alibaba-NLP/gte-Qwen2-0.6B-instruct
    Zero API calls, fully offline.

    Requires optional deps: {:bumblebee, "~> 0.6"}, {:exla, "~> 0.9"}

    ## Options

      * `:model` - HuggingFace model repo (default: "Alibaba-NLP/gte-Qwen2-0.6B-instruct")
      * `:backend` - Nx backend module (default: EXLA.Backend if available)
    """

    @behaviour Nous.Memory.Embedding

    @default_model "Alibaba-NLP/gte-Qwen2-0.6B-instruct"
    @default_dimension 1024

    @impl true
    def embed(text, opts \\ []) do
      model_name = opts[:model] || @default_model

      with {:ok, serving} <- get_or_start_serving(model_name, opts) do
        result = Nx.Serving.run(serving, text)
        embedding = result.embedding |> Nx.to_flat_list()
        {:ok, embedding}
      end
    end

    @impl true
    def embed_batch(texts, opts \\ []) do
      model_name = opts[:model] || @default_model

      with {:ok, serving} <- get_or_start_serving(model_name, opts) do
        results = Nx.Serving.run(serving, texts)

        embeddings =
          results.embedding
          |> Nx.to_batched(1)
          |> Enum.map(&Nx.to_flat_list/1)

        {:ok, embeddings}
      end
    end

    @impl true
    def dimension, do: @default_dimension

    defp get_or_start_serving(model_name, opts) do
      key = {__MODULE__, model_name}

      case :persistent_term.get(key, nil) do
        nil -> start_serving(model_name, opts, key)
        serving -> {:ok, serving}
      end
    end

    defp start_serving(model_name, opts, key) do
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

        :persistent_term.put(key, serving)
        {:ok, serving}
      end
    rescue
      e -> {:error, Exception.message(e)}
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
