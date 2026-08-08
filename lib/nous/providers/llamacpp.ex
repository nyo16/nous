if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.Providers.LlamaCpp do
    @moduledoc """
    LlamaCpp NIF-based provider for local LLM inference.

    Runs GGUF models directly in-process via `llama_cpp_ex` NIF bindings.
    No HTTP server needed.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.8"}`

    ## Usage

        # Load model once at app start
        :ok = LlamaCppEx.init()
        {:ok, llm} = LlamaCppEx.load_model("model.gguf", n_gpu_layers: -1)

        # Use with Nous
        agent = Nous.new("llamacpp:local",
          llamacpp_model: llm,
          instructions: "You are helpful."
        )

        {:ok, result} = Nous.run(agent, "What is Elixir?")

    ## Configuration

    The `llamacpp_model` (the loaded model reference) must be passed via options
    when creating the model or agent. It is stored in `default_settings`.

    No API key or base URL is needed since inference runs locally via NIFs.

    ## Settings Mapping

    Nous settings are mapped to LlamaCppEx options:

    | Nous Setting | LlamaCppEx Option | Description |
    |---|---|---|
    | `:temperature` | `:temp` | Sampling temperature |
    | `:max_tokens` | `:max_tokens` | Maximum tokens to generate |
    | `:top_p` | `:top_p` | Nucleus sampling |
    | `:json_schema` | `:json_schema` | Constrained JSON output |
    | `:enable_thinking` | `:enable_thinking` | Enable/disable thinking tokens |

    ## Thinking Models

    Models like Qwen3 emit `<think>...</think>` tags by default. To disable:

        agent = Nous.new("llamacpp:local",
          llamacpp_model: llm,
          model_settings: %{enable_thinking: false}
        )

    Or via `generate_text`:

        {:ok, text} = Nous.generate_text("llamacpp:local", "Hello",
          llamacpp_model: llm,
          enable_thinking: false
        )
    """

    use Nous.Provider,
      id: :llamacpp,
      default_base_url: "local",
      default_env_key: "LLAMACPP_MODEL_PATH"

    require Logger

    @impl Nous.Provider
    def chat(_params, _opts \\ []) do
      {:error, :use_request_api}
    end

    @impl Nous.Provider
    def chat_stream(_params, _opts \\ []) do
      {:error, :use_request_api}
    end

    @impl Nous.Provider
    def request(model, messages, settings) do
      merged_settings = Map.merge(model.default_settings, settings)

      case merged_settings[:llamacpp_model] do
        nil -> {:error, missing_model_error()}
        llamacpp_model -> do_request(model, messages, merged_settings, llamacpp_model)
      end
    end

    defp do_request(model, messages, merged_settings, llamacpp_model) do
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:nous, :provider, :request, :start],
        %{system_time: System.system_time(), monotonic_time: start_time},
        %{provider: :llamacpp, model_name: model.model, message_count: length(messages)}
      )

      provider_messages =
        messages
        |> Nous.Messages.to_provider_format(:llamacpp)
        |> to_atom_key_messages()

      opts = build_llamacpp_opts(merged_settings)

      result = run_chat_completion(llamacpp_model, provider_messages, opts)

      Nous.Provider.emit_request_telemetry(
        result,
        :llamacpp,
        model,
        System.monotonic_time() - start_time
      )

      result
    end

    defp run_chat_completion(llamacpp_model, provider_messages, opts) do
      case LlamaCppEx.chat_completion(llamacpp_model, provider_messages, opts) do
        {:ok, completion} ->
          {:ok, Nous.Messages.from_provider_response(completion_to_map(completion), :llamacpp)}

        {:error, error} ->
          {:error,
           Nous.Errors.ProviderError.exception(
             provider: :llamacpp,
             message: "Request failed: #{inspect(error)}",
             details: error
           )}
      end
    end

    @impl Nous.Provider
    def request_stream(model, messages, settings) do
      merged_settings = Map.merge(model.default_settings, settings)

      case merged_settings[:llamacpp_model] do
        nil -> {:error, missing_model_error()}
        llamacpp_model -> do_request_stream(model, messages, merged_settings, llamacpp_model)
      end
    end

    defp do_request_stream(model, messages, merged_settings, llamacpp_model) do
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:nous, :provider, :stream, :start],
        %{system_time: System.system_time(), monotonic_time: start_time},
        %{provider: :llamacpp, model_name: model.model, message_count: length(messages)}
      )

      provider_messages =
        messages
        |> Nous.Messages.to_provider_format(:llamacpp)
        |> to_atom_key_messages()

      opts = build_llamacpp_opts(merged_settings)

      # LlamaCppEx.stream_chat_completion/3 is spec'd `:: Enumerable.t()` — it
      # returns a raw lazy stream, never an {:ok,_}/{:error,_} tuple. Generation
      # errors surface during enumeration (via the normalizer), not as a
      # setup-time error here.
      stream = LlamaCppEx.stream_chat_completion(llamacpp_model, provider_messages, opts)

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:nous, :provider, :stream, :connected],
        %{duration: duration},
        %{provider: :llamacpp, model_name: model.model}
      )

      normalizer = model.stream_normalizer || default_stream_normalizer()
      transformed_stream = Nous.StreamNormalizer.normalize(stream, normalizer)
      {:ok, transformed_stream}
    end

    # This provider dispatches to the NIF directly via its own request/3 and
    # request_stream/3, so it never builds wire params. We still define
    # build_request_params/3 (rather than leaving the macro default, which is
    # dead-code-eliminated when unused) because `use Nous.Provider` injects a
    # `@dialyzer {:nowarn_function, build_request_params: 3}` that would
    # otherwise dangle ("Unknown function"). It's a public `@doc false` stub so
    # the compiler doesn't flag it as an unused private function.
    @doc false
    @spec build_request_params(Nous.Model.t(), list(), map()) :: map()
    def build_request_params(_model, _messages, _settings), do: %{}

    defp default_stream_normalizer, do: Nous.StreamNormalizer.LlamaCpp

    defp missing_model_error do
      Nous.Errors.ProviderError.exception(
        provider: :llamacpp,
        message:
          "llamacpp provider requires :llamacpp_model option. " <>
            "Pass it when creating the agent: Nous.new(\"llamacpp:local\", llamacpp_model: llm)",
        details: :missing_llamacpp_model
      )
    end

    # Convert string-keyed maps from to_openai_format to atom-keyed maps for LlamaCppEx.
    # NEVER call String.to_atom/1 on data flowing from to_openai_format - if the keyset
    # ever expands to include user-controlled fields, that becomes an atom-table DoS.
    # Whitelist the known message-shape keys; unknown keys stay as binaries.
    @llamacpp_message_keys %{
      "role" => :role,
      "content" => :content,
      "name" => :name,
      "tool_calls" => :tool_calls,
      "tool_call_id" => :tool_call_id,
      "id" => :id,
      "type" => :type,
      "function" => :function,
      "arguments" => :arguments
    }

    defp to_atom_keys(map) when is_map(map) do
      Map.new(map, fn
        {k, v} when is_binary(k) -> {Map.get(@llamacpp_message_keys, k, k), v}
        {k, v} -> {k, v}
      end)
    end

    # The llamacpp path converts twice: to the OpenAI shape, then to atom keys.
    # Memoize the second pass as well — the maps `to_provider_format/2` returns
    # are themselves cached, so the prefix shared with the previous iteration is
    # pointer-identical and never re-keyed.
    defp to_atom_key_messages(provider_messages) do
      Nous.Messages.Cache.map({__MODULE__, :atom_keys}, provider_messages, &to_atom_keys/1)
    end

    # Build LlamaCppEx options from Nous settings
    defp build_llamacpp_opts(settings) do
      opts = []

      opts = if settings[:temperature], do: [{:temp, settings[:temperature]} | opts], else: opts

      opts =
        if settings[:max_tokens], do: [{:max_tokens, settings[:max_tokens]} | opts], else: opts

      opts = if settings[:top_p], do: [{:top_p, settings[:top_p]} | opts], else: opts

      opts =
        if settings[:json_schema], do: [{:json_schema, settings[:json_schema]} | opts], else: opts

      opts =
        if Map.has_key?(settings, :enable_thinking),
          do: [{:enable_thinking, settings[:enable_thinking]} | opts],
          else: opts

      opts
    end

    # Convert a %ChatCompletion{} struct to a string-keyed map compatible with from_openai_response/1
    defp completion_to_map(completion) do
      choices = Enum.map(completion.choices, &choice_to_map/1)

      usage_data = Map.get(completion, :usage)

      usage =
        if usage_data do
          %{
            "prompt_tokens" => Map.get(usage_data, :prompt_tokens),
            "completion_tokens" => Map.get(usage_data, :completion_tokens),
            "total_tokens" => Map.get(usage_data, :total_tokens)
          }
        end

      map = %{
        "id" => Map.get(completion, :id),
        "object" => "chat.completion",
        "choices" => choices
      }

      if usage, do: Map.put(map, "usage", usage), else: map
    end

    defp choice_to_map(choice) do
      msg = choice.message || %{}

      message = %{
        "role" => to_string(Map.get(msg, :role, "assistant")),
        "content" => Map.get(msg, :content)
      }

      %{
        "index" => Map.get(choice, :index, 0),
        "message" => put_tool_calls(message, Map.get(msg, :tool_calls)),
        "finish_reason" => Map.get(choice, :finish_reason)
      }
    end

    defp put_tool_calls(message, tool_calls) when tool_calls in [nil, []], do: message

    defp put_tool_calls(message, tool_calls) do
      Map.put(message, "tool_calls", Enum.map(tool_calls, &tool_call_to_map/1))
    end

    defp tool_call_to_map(tc) do
      %{
        "id" => tc.id,
        "type" => "function",
        "function" => %{"name" => tc.function.name, "arguments" => tc.function.arguments}
      }
    end
  end
else
  defmodule Nous.Providers.LlamaCpp do
    @moduledoc """
    LlamaCpp NIF-based provider for local LLM inference.

    **Not available** - add `{:llama_cpp_ex, "~> 0.8"}` to your mix.exs deps.
    """

    @behaviour Nous.Provider

    @not_available "LlamaCppEx is not available. Add {:llama_cpp_ex, \"~> 0.8\"} to your mix.exs deps."

    @impl true
    def provider_id, do: :llamacpp

    @impl true
    def default_base_url, do: "local"

    @impl true
    def default_env_key, do: "LLAMACPP_MODEL_PATH"

    @impl true
    def chat(_params, _opts \\ []), do: {:error, @not_available}

    @impl true
    def chat_stream(_params, _opts \\ []), do: {:error, @not_available}

    @impl true
    def request(_model, _messages, _settings) do
      {:error,
       Nous.Errors.ProviderError.exception(
         provider: :llamacpp,
         message: @not_available,
         details: :not_available
       )}
    end

    @impl true
    def request_stream(_model, _messages, _settings) do
      {:error,
       Nous.Errors.ProviderError.exception(
         provider: :llamacpp,
         message: @not_available,
         details: :not_available
       )}
    end

    # ≈4 bytes/token over binary content only — same estimator as the
    # `Nous.Provider` default and `RequestDispatch.estimate_request_tokens/1`.
    # The old `inspect |> String.length |> div(4)` copied and escaped the whole
    # message, then walked it grapheme-by-grapheme (135 µs vs 0.01 µs / 10 KB).
    @impl true
    def count_tokens(messages) do
      Enum.reduce(messages, 0, fn
        %{content: content}, acc when is_binary(content) -> acc + div(byte_size(content), 4)
        _message, acc -> acc
      end)
    end
  end
end
