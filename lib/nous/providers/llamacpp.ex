if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.Providers.LlamaCpp do
    @moduledoc """
    LlamaCpp NIF-based provider for local LLM inference.

    Runs GGUF models directly in-process via `llama_cpp_ex` NIF bindings.
    No HTTP server needed.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.5.0"}`

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
      start_time = System.monotonic_time()
      merged_settings = Map.merge(model.default_settings, settings)

      llamacpp_model = merged_settings[:llamacpp_model]

      unless llamacpp_model do
        raise ArgumentError,
              "llamacpp provider requires :llamacpp_model option. " <>
                "Pass it when creating the agent: Nous.new(\"llamacpp:local\", llamacpp_model: llm)"
      end

      :telemetry.execute(
        [:nous, :provider, :request, :start],
        %{system_time: System.system_time(), monotonic_time: start_time},
        %{provider: :llamacpp, model_name: model.model, message_count: length(messages)}
      )

      provider_messages =
        messages
        |> Nous.Messages.to_provider_format(:llamacpp)
        |> Enum.map(&to_atom_keys/1)

      opts = build_llamacpp_opts(merged_settings)

      result =
        case LlamaCppEx.chat_completion(llamacpp_model, provider_messages, opts) do
          {:ok, completion} ->
            response_map = completion_to_map(completion)
            parsed = Nous.Messages.from_provider_response(response_map, :llamacpp)
            {:ok, parsed}

          {:error, error} ->
            wrapped =
              Nous.Errors.ProviderError.exception(
                provider: :llamacpp,
                message: "Request failed: #{inspect(error)}",
                details: error
              )

            {:error, wrapped}
        end

      duration = System.monotonic_time() - start_time

      case result do
        {:ok, parsed_response} ->
          usage =
            case parsed_response.metadata do
              %{usage: %Nous.Usage{} = u} -> u
              %{usage: u} when is_map(u) -> u
              _ -> %{}
            end

          :telemetry.execute(
            [:nous, :provider, :request, :stop],
            %{
              duration: duration,
              input_tokens: Map.get(usage, :input_tokens) || 0,
              output_tokens: Map.get(usage, :output_tokens) || 0,
              total_tokens: Map.get(usage, :total_tokens) || 0
            },
            %{
              provider: :llamacpp,
              model_name: model.model,
              has_tool_calls: length(parsed_response.tool_calls) > 0
            }
          )

        {:error, error} ->
          :telemetry.execute(
            [:nous, :provider, :request, :exception],
            %{duration: duration},
            %{provider: :llamacpp, model_name: model.model, kind: :error, reason: error}
          )
      end

      result
    end

    @impl Nous.Provider
    def request_stream(model, messages, settings) do
      start_time = System.monotonic_time()
      merged_settings = Map.merge(model.default_settings, settings)

      llamacpp_model = merged_settings[:llamacpp_model]

      unless llamacpp_model do
        raise ArgumentError,
              "llamacpp provider requires :llamacpp_model option. " <>
                "Pass it when creating the agent: Nous.new(\"llamacpp:local\", llamacpp_model: llm)"
      end

      :telemetry.execute(
        [:nous, :provider, :stream, :start],
        %{system_time: System.system_time(), monotonic_time: start_time},
        %{provider: :llamacpp, model_name: model.model, message_count: length(messages)}
      )

      provider_messages =
        messages
        |> Nous.Messages.to_provider_format(:llamacpp)
        |> Enum.map(&to_atom_keys/1)

      opts = build_llamacpp_opts(merged_settings)

      stream_result = LlamaCppEx.stream_chat_completion(llamacpp_model, provider_messages, opts)

      # LlamaCppEx may return {:ok, stream} or the stream directly
      stream_result =
        case stream_result do
          {:ok, _} -> stream_result
          {:error, _} -> stream_result
          stream -> {:ok, stream}
        end

      case stream_result do
        {:ok, stream} ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:nous, :provider, :stream, :connected],
            %{duration: duration},
            %{provider: :llamacpp, model_name: model.model}
          )

          normalizer = model.stream_normalizer || Nous.StreamNormalizer.LlamaCpp
          transformed_stream = Nous.StreamNormalizer.normalize(stream, normalizer)
          {:ok, transformed_stream}

        {:error, error} ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:nous, :provider, :stream, :exception],
            %{duration: duration},
            %{provider: :llamacpp, model_name: model.model, kind: :error, reason: error}
          )

          wrapped =
            Nous.Errors.ProviderError.exception(
              provider: :llamacpp,
              message: "Streaming request failed: #{inspect(error)}",
              details: error
            )

          {:error, wrapped}
      end
    end

    # Override macro-injected private functions that would otherwise be dead code
    # (since we override request/3 and request_stream/3 which are their only callers)
    defp default_stream_normalizer, do: Nous.StreamNormalizer.LlamaCpp
    defp build_request_params(_model, _messages, _settings), do: %{}

    # Convert string-keyed maps from to_openai_format to atom-keyed maps for LlamaCppEx
    defp to_atom_keys(map) when is_map(map) do
      Map.new(map, fn
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
        {k, v} -> {k, v}
      end)
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
      choices =
        Enum.map(completion.choices, fn choice ->
          msg = choice.message || %{}

          message = %{
            "role" => to_string(Map.get(msg, :role, "assistant")),
            "content" => Map.get(msg, :content)
          }

          tool_calls = Map.get(msg, :tool_calls)

          message =
            if tool_calls && tool_calls != [] do
              converted =
                Enum.map(tool_calls, fn tc ->
                  %{
                    "id" => tc.id,
                    "type" => "function",
                    "function" => %{
                      "name" => tc.function.name,
                      "arguments" => tc.function.arguments
                    }
                  }
                end)

              Map.put(message, "tool_calls", converted)
            else
              message
            end

          %{
            "index" => Map.get(choice, :index, 0),
            "message" => message,
            "finish_reason" => Map.get(choice, :finish_reason)
          }
        end)

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
  end
else
  defmodule Nous.Providers.LlamaCpp do
    @moduledoc """
    LlamaCpp NIF-based provider for local LLM inference.

    **Not available** - add `{:llama_cpp_ex, "~> 0.5.0"}` to your mix.exs deps.
    """

    @behaviour Nous.Provider

    @not_available "LlamaCppEx is not available. Add {:llama_cpp_ex, \"~> 0.5.0\"} to your mix.exs deps."

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

    @impl true
    def count_tokens(messages),
      do: messages |> Enum.map(&(inspect(&1) |> String.length() |> div(4))) |> Enum.sum()
  end
end
