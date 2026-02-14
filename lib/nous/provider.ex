defmodule Nous.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Provides a declarative way to define providers with common functionality
  injected via the `use` macro.

  ## Usage

      defmodule Nous.Providers.OpenAI do
        use Nous.Provider,
          id: :openai,
          default_base_url: "https://api.openai.com/v1",
          default_env_key: "OPENAI_API_KEY"

        @impl true
        def chat(params, opts \\\\ []) do
          # Implementation
        end

        @impl true
        def chat_stream(params, opts \\\\ []) do
          # Implementation
        end
      end

  ## Callbacks

  Providers must implement:
  - `chat/2` - Non-streaming chat completion (low-level HTTP)
  - `chat_stream/2` - Streaming chat completion (low-level HTTP)

  Optional (have default implementations):
  - `request/3` - High-level request with message conversion, telemetry, error wrapping
  - `request_stream/3` - High-level streaming with message conversion, telemetry
  - `count_tokens/1` - Token counting (defaults to rough estimate)

  ## Injected Functions

  The `use` macro injects:
  - `provider_id/0` - Returns the provider atom ID
  - `default_base_url/0` - Returns the default API base URL
  - `default_env_key/0` - Returns the environment variable name for API key
  - `api_key/1` - Returns the API key from opts, env, or config
  - `base_url/1` - Returns base URL from opts, config, or default
  - `request/3` - High-level request (can be overridden)
  - `request_stream/3` - High-level streaming request (can be overridden)
  """

  alias Nous.Model

  @doc "Returns the provider identifier atom"
  @callback provider_id() :: atom()

  @doc "Returns the default API base URL"
  @callback default_base_url() :: String.t()

  @doc "Returns the environment variable name for the API key"
  @callback default_env_key() :: String.t()

  @doc """
  Make a non-streaming chat request (low-level HTTP).

  ## Parameters
    * `params` - Request parameters (model, messages, etc.)
    * `opts` - Options including :api_key, :base_url, :timeout

  ## Returns
    * `{:ok, response}` - Parsed response body
    * `{:error, reason}` - Error with reason
  """
  @callback chat(params :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Make a streaming chat request (low-level HTTP).

  ## Parameters
    * `params` - Request parameters (model, messages, etc.)
    * `opts` - Options including :api_key, :base_url, :timeout

  ## Returns
    * `{:ok, stream}` - Enumerable of parsed events
    * `{:error, reason}` - Error with reason
  """
  @callback chat_stream(params :: map(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  High-level request with message conversion, telemetry, and error wrapping.

  ## Parameters
    * `model` - Model configuration struct
    * `messages` - List of messages in internal format
    * `settings` - Request settings (temperature, max_tokens, tools, etc.)

  ## Returns
    * `{:ok, message}` - Parsed response as Message struct
    * `{:error, error}` - Wrapped error
  """
  @callback request(model :: Model.t(), messages :: list(), settings :: map()) ::
              {:ok, Nous.Message.t()} | {:error, term()}

  @doc """
  High-level streaming request with message conversion and telemetry.

  ## Parameters
    * `model` - Model configuration struct
    * `messages` - List of messages in internal format
    * `settings` - Request settings

  ## Returns
    * `{:ok, stream}` - Stream of normalized events
    * `{:error, error}` - Wrapped error
  """
  @callback request_stream(model :: Model.t(), messages :: list(), settings :: map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Count tokens in messages (can be an estimate).

  Optional callback - defaults to rough estimation if not implemented.
  """
  @callback count_tokens(messages :: list()) :: integer()

  @optional_callbacks [count_tokens: 1, request: 3, request_stream: 3]

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    default_base_url = Keyword.fetch!(opts, :default_base_url)
    default_env_key = Keyword.fetch!(opts, :default_env_key)

    quote do
      @behaviour Nous.Provider

      @provider_id unquote(id)
      @default_base_url unquote(default_base_url)
      @default_env_key unquote(default_env_key)

      @impl Nous.Provider
      def provider_id, do: @provider_id

      @impl Nous.Provider
      def default_base_url, do: @default_base_url

      @impl Nous.Provider
      def default_env_key, do: @default_env_key

      @doc """
      Get the API key from options, environment, or application config.

      Lookup order:
      1. `:api_key` option passed directly
      2. Environment variable (#{unquote(default_env_key)})
      3. Application config: `config :nous, #{unquote(id)}, api_key: "..."`
      """
      @spec api_key(keyword()) :: String.t() | nil
      def api_key(opts \\ []) do
        Keyword.get(opts, :api_key) ||
          System.get_env(@default_env_key) ||
          get_in(Application.get_env(:nous, @provider_id, []), [:api_key])
      end

      @doc """
      Get the base URL from options, application config, or default.

      Lookup order:
      1. `:base_url` option passed directly
      2. Application config: `config :nous, #{unquote(id)}, base_url: "..."`
      3. Default: #{unquote(default_base_url)}
      """
      @spec base_url(keyword()) :: String.t()
      def base_url(opts \\ []) do
        Keyword.get(opts, :base_url) ||
          get_in(Application.get_env(:nous, @provider_id, []), [:base_url]) ||
          @default_base_url
      end

      @doc """
      Count tokens in messages (rough estimate).

      Override this in your provider for more accurate counting.
      """
      @impl Nous.Provider
      @spec count_tokens(list()) :: integer()
      def count_tokens(messages) do
        messages
        |> Enum.map(&estimate_message_tokens/1)
        |> Enum.sum()
      end

      defp estimate_message_tokens(message) do
        message |> inspect() |> String.length() |> div(4)
      end

      @doc """
      High-level request with message conversion, telemetry, and error wrapping.

      Default implementation that:
      1. Converts messages to provider format
      2. Builds request params
      3. Calls chat/2
      4. Parses response
      5. Emits telemetry events
      6. Wraps errors
      """
      @impl Nous.Provider
      def request(model, messages, settings) do
        start_time = System.monotonic_time()

        # Emit start event
        :telemetry.execute(
          [:nous, :provider, :request, :start],
          %{system_time: System.system_time(), monotonic_time: start_time},
          %{
            provider: @provider_id,
            model_name: model.model,
            message_count: length(messages)
          }
        )

        # Build request params and options
        params = build_request_params(model, messages, settings)
        opts = build_provider_opts(model)

        # Make request
        result =
          case chat(params, opts) do
            {:ok, response} ->
              parsed = Nous.Messages.from_provider_response(response, @provider_id)
              {:ok, parsed}

            {:error, error} ->
              wrapped_error =
                Nous.Errors.ProviderError.exception(
                  provider: @provider_id,
                  message: "Request failed: #{inspect(error)}",
                  details: error
                )

              {:error, wrapped_error}
          end

        # Emit telemetry
        duration = System.monotonic_time() - start_time

        case result do
          {:ok, parsed_response} ->
            # Extract usage - handle both Usage struct and map
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
                provider: @provider_id,
                model_name: model.model,
                has_tool_calls: length(parsed_response.tool_calls || []) > 0
              }
            )

          {:error, error} ->
            :telemetry.execute(
              [:nous, :provider, :request, :exception],
              %{duration: duration},
              %{
                provider: @provider_id,
                model_name: model.model,
                kind: :error,
                reason: error
              }
            )
        end

        result
      end

      @doc """
      High-level streaming request with message conversion and telemetry.
      """
      @impl Nous.Provider
      def request_stream(model, messages, settings) do
        start_time = System.monotonic_time()

        # Emit start event
        :telemetry.execute(
          [:nous, :provider, :stream, :start],
          %{system_time: System.system_time(), monotonic_time: start_time},
          %{
            provider: @provider_id,
            model_name: model.model,
            message_count: length(messages)
          }
        )

        # Build request params and options
        params = build_request_params(model, messages, settings)
        opts = build_provider_opts(model)

        case chat_stream(params, opts) do
          {:ok, stream} ->
            duration = System.monotonic_time() - start_time

            # Emit connected event
            :telemetry.execute(
              [:nous, :provider, :stream, :connected],
              %{duration: duration},
              %{
                provider: @provider_id,
                model_name: model.model
              }
            )

            # Transform stream using normalizer
            normalizer = model.stream_normalizer || default_stream_normalizer()
            transformed_stream = Nous.StreamNormalizer.normalize(stream, normalizer)
            {:ok, transformed_stream}

          {:error, error} ->
            duration = System.monotonic_time() - start_time

            :telemetry.execute(
              [:nous, :provider, :stream, :exception],
              %{duration: duration},
              %{
                provider: @provider_id,
                model_name: model.model,
                kind: :error,
                reason: error
              }
            )

            wrapped_error =
              Nous.Errors.ProviderError.exception(
                provider: @provider_id,
                message: "Streaming request failed: #{inspect(error)}",
                details: error
              )

            {:error, wrapped_error}
        end
      end

      # Build provider options from model config
      defp build_provider_opts(model) do
        opts = [
          base_url: model.base_url,
          api_key: model.api_key,
          timeout: model.receive_timeout,
          finch_name: Application.get_env(:nous, :finch, Nous.Finch)
        ]

        # Add organization if present
        if model.organization do
          Keyword.put(opts, :organization, model.organization)
        else
          opts
        end
      end

      # Build request parameters - can be overridden by specific providers
      defp build_request_params(model, messages, settings) do
        # Merge model defaults with request settings
        merged_settings = Map.merge(model.default_settings, settings)

        # Convert messages to provider format
        provider_messages = Nous.Messages.to_provider_format(messages, @provider_id)

        # Handle providers that return {system, messages} vs just messages
        {system_prompt, formatted_messages} =
          case provider_messages do
            {sys, msgs} -> {sys, msgs}
            msgs when is_list(msgs) -> {nil, msgs}
          end

        # Build base parameters
        base_params = %{
          "model" => model.model,
          "messages" => formatted_messages
        }

        # Add system prompt if present (for Anthropic/Gemini style)
        base_params =
          if system_prompt do
            Map.put(base_params, "system", system_prompt)
          else
            base_params
          end

        # Add optional parameters
        base_params
        |> maybe_put("temperature", merged_settings[:temperature])
        |> maybe_put("max_tokens", merged_settings[:max_tokens])
        |> maybe_put("top_p", merged_settings[:top_p])
        |> maybe_put("frequency_penalty", merged_settings[:frequency_penalty])
        |> maybe_put("presence_penalty", merged_settings[:presence_penalty])
        |> maybe_put("stop", merged_settings[:stop_sequences])
        |> maybe_put("tools", merged_settings[:tools])
        |> maybe_put("tool_choice", merged_settings[:tool_choice])
      end

      defp maybe_put(params, _key, nil), do: params
      defp maybe_put(params, key, value), do: Map.put(params, key, value)

      # Default stream normalizer - providers can override
      defp default_stream_normalizer do
        case @provider_id do
          :anthropic -> Nous.StreamNormalizer.Anthropic
          :gemini -> Nous.StreamNormalizer.Gemini
          _ -> Nous.StreamNormalizer.OpenAI
        end
      end

      defoverridable count_tokens: 1,
                     request: 3,
                     request_stream: 3,
                     build_request_params: 3,
                     build_provider_opts: 1,
                     default_stream_normalizer: 0
    end
  end
end
