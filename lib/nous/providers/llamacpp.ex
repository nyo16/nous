if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.Providers.LlamaCpp do
    @moduledoc """
    LlamaCpp NIF-based provider for local LLM inference.

    Runs GGUF models directly in-process via `llama_cpp_ex` NIF bindings.
    No HTTP server needed.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.8.63"}`

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
    | `:json_schema` | `:grammar` | Constrained JSON output: the schema is compiled to a GBNF grammar. An agent's `output_type` sets it when the agent has no tools. A schema llama.cpp cannot compile returns `{:error, %Nous.Errors.ConfigurationError{}}` |
    | `:enable_thinking` | `:enable_thinking` | Enable/disable thinking tokens |
    | `:tools` | `:tools` | The agent's tools, OpenAI-shaped (set by the agent runner) |
    | `:tool_choice` | `:tool_choice` | `"auto"` (default), `"none"`, `"required"` or `%{"type" => "function", "function" => %{"name" => name}}` |
    | `:parallel_tool_calls` | `:parallel_tool_calls` | Let the model emit several calls in one reply (llama_cpp_ex default: `false`). Set it in `model_settings`; the agent's `parallel_tool_calls:` option only controls running tools concurrently |

    ## Tool Calling

    The agent's tools go to `LlamaCppEx.chat_completion/3` and
    `LlamaCppEx.stream_chat_completion/3`. The model's chat template renders
    them and supplies the grammar and parser for its call format, so the reply
    comes back as `tool_calls` (streamed as `{:tool_call_delta, _}` events) and
    the agent loop runs the tools as with any other provider. This needs a model
    whose template supports tools (Qwen3 / Qwen3.5, Llama 3.x, ...). With any
    other model the request fails with llama.cpp's "does not support tool calls"
    error instead of silently dropping the tools.

    llama.cpp cannot apply a JSON-schema grammar and the tool-call grammar at
    once. An agent with tools and an `output_type` therefore gets its output as
    a synthetic tool call (`Nous.OutputSchema`'s `:tool_call` mode, the default
    for `llamacpp` when the agent has tools). An explicit
    `structured_output: [mode: :json_schema]` together with tools is a
    `Nous.Errors.ConfigurationError`.

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

      with llamacpp_model when not is_nil(llamacpp_model) <- merged_settings[:llamacpp_model],
           {:ok, opts} <- build_llamacpp_opts(merged_settings) do
        do_request(model, messages, opts, llamacpp_model)
      else
        nil -> {:error, missing_model_error()}
        {:error, _} = error -> error
      end
    end

    defp do_request(model, messages, opts, llamacpp_model) do
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:nous, :provider, :request, :start],
        %{system_time: System.system_time(), monotonic_time: start_time},
        %{provider: :llamacpp, model_name: model.model, message_count: length(messages)}
      )

      provider_messages =
        messages
        |> Nous.Messages.to_provider_format(:llamacpp)
        |> Enum.map(&to_atom_keys/1)

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
      merged_settings = Map.merge(model.default_settings, settings)

      with llamacpp_model when not is_nil(llamacpp_model) <- merged_settings[:llamacpp_model],
           {:ok, opts} <- build_llamacpp_opts(merged_settings) do
        do_request_stream(model, messages, opts, llamacpp_model)
      else
        nil -> {:error, missing_model_error()}
        {:error, _} = error -> error
      end
    end

    defp do_request_stream(model, messages, opts, llamacpp_model) do
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:nous, :provider, :stream, :start],
        %{system_time: System.system_time(), monotonic_time: start_time},
        %{provider: :llamacpp, model_name: model.model, message_count: length(messages)}
      )

      provider_messages =
        messages
        |> Nous.Messages.to_provider_format(:llamacpp)
        |> Enum.map(&to_atom_keys/1)

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

    # Build LlamaCppEx options from Nous settings.
    #
    # `:json_schema` (set by Nous.OutputSchema for `output_type`, or passed
    # directly) is compiled to a GBNF grammar here rather than handed to
    # LlamaCppEx as-is, so a schema llama.cpp cannot convert is a typed
    # `ConfigurationError` before any generation, on the streaming path too
    # (where LlamaCppEx would report it as an in-stream error element).
    #
    # `:tools` arrive OpenAI-shaped (Nous.Tool.to_openai_schema/1, string
    # keys), which is the shape LlamaCppEx renders through the chat template.
    defp build_llamacpp_opts(settings) do
      opts = []

      opts = if settings[:temperature], do: [{:temp, settings[:temperature]} | opts], else: opts

      opts =
        if settings[:max_tokens], do: [{:max_tokens, settings[:max_tokens]} | opts], else: opts

      opts = if settings[:top_p], do: [{:top_p, settings[:top_p]} | opts], else: opts

      opts =
        if Map.has_key?(settings, :enable_thinking),
          do: [{:enable_thinking, settings[:enable_thinking]} | opts],
          else: opts

      with {:ok, opts} <- with_tools(opts, settings) do
        case settings[:json_schema] do
          nil -> {:ok, opts}
          schema -> with_grammar(opts, schema)
        end
      end
    end

    defp with_tools(opts, settings) do
      case settings[:tools] do
        tools when tools in [nil, []] ->
          {:ok, opts}

        tools when is_list(tools) ->
          with :ok <- check_tool_entries(tools),
               {:ok, choice} <- tool_choice(settings[:tool_choice]),
               :ok <- check_tool_grammar(choice, settings) do
            opts = [{:tools, tools}, {:tool_choice, choice} | opts]

            opts =
              if is_boolean(settings[:parallel_tool_calls]),
                do: [{:parallel_tool_calls, settings[:parallel_tool_calls]} | opts],
                else: opts

            {:ok, opts}
          end

        other ->
          {:error, invalid_tools(other)}
      end
    end

    # The runner always sends a list of OpenAI-shaped maps; a raw `:tools` in
    # `model_settings` may not be. LlamaCppEx raises (or fails to JSON-encode)
    # on anything else, so that is a typed error here rather than a crash.
    defp check_tool_entries(tools) do
      if Enum.all?(tools, &(is_map(&1) and not is_struct(&1))),
        do: :ok,
        else: {:error, invalid_tools(tools)}
    end

    defp invalid_tools(tools) do
      Nous.Errors.ConfigurationError.exception(
        message:
          "llamacpp :tools must be a list of OpenAI-shaped tool maps " <>
            "(%{\"type\" => \"function\", \"function\" => %{...}}), got: " <>
            inspect(tools, limit: 5),
        details: %{provider: :llamacpp}
      )
    end

    # The OpenAI shapes Nous produces (strings, or the named-function map
    # Nous.OutputSchema's :tool_call mode uses); LlamaCppEx accepts all of
    # them but raises on anything else, so that is a typed error here.
    defp tool_choice(nil), do: {:ok, :auto}
    defp tool_choice(choice) when choice in [:auto, :none, :required], do: {:ok, choice}

    defp tool_choice("auto"), do: {:ok, :auto}
    defp tool_choice("none"), do: {:ok, :none}
    defp tool_choice("required"), do: {:ok, :required}

    defp tool_choice(%{"type" => "function", "function" => %{"name" => name}} = choice)
         when is_binary(name),
         do: {:ok, choice}

    defp tool_choice(%{type: "function", function: %{name: name}} = choice) when is_binary(name),
      do: {:ok, choice}

    defp tool_choice(other) do
      {:error,
       Nous.Errors.ConfigurationError.exception(
         message:
           "invalid :tool_choice #{inspect(other)} for llamacpp; expected \"auto\", " <>
             "\"none\", \"required\" or %{\"type\" => \"function\", \"function\" => %{\"name\" => name}}",
         details: %{provider: :llamacpp, tool_choice: other}
       )}
    end

    # llama.cpp constrains a tool call with the chat template's own grammar, so
    # a JSON-schema grammar cannot apply at the same time (LlamaCppEx raises
    # ArgumentError, as llama-server refuses). `output_type` with tools uses
    # the :tool_call mode by default (Nous.OutputSchema); this is the explicit
    # `structured_output: [mode: :json_schema]` (or a raw `:json_schema`
    # setting) together with tools.
    defp check_tool_grammar(:none, _settings), do: :ok

    defp check_tool_grammar(_choice, settings) do
      if settings[:json_schema] do
        {:error,
         Nous.Errors.ConfigurationError.exception(
           message:
             "llama.cpp cannot constrain output with a JSON schema while tools are offered " <>
               "(the chat template supplies the tool-call grammar). Use output_type's default " <>
               "mode (:tool_call when the agent has tools) instead of mode: :json_schema.",
           details: %{provider: :llamacpp}
         )}
      else
        :ok
      end
    end

    defp with_grammar(opts, schema) do
      case LlamaCppEx.Grammar.from_json_schema(schema) do
        {:ok, gbnf} ->
          {:ok, [{:grammar, gbnf} | opts]}

        {:error, reason} ->
          {:error,
           Nous.Errors.ConfigurationError.exception(
             message: "llama.cpp cannot compile this JSON schema to a grammar: #{reason}",
             details: %{provider: :llamacpp, json_schema: schema}
           )}
      end
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

    **Not available** - add `{:llama_cpp_ex, "~> 0.8.63"}` to your mix.exs deps.
    """

    @behaviour Nous.Provider

    @not_available "LlamaCppEx is not available. Add {:llama_cpp_ex, \"~> 0.8.63\"} to your mix.exs deps."

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
