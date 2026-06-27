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

    # Optionally inject the shared OpenAI-compatible `chat/2` + `chat_stream/2`
    # implementations (plus base-URL resolution and header helpers). Providers
    # that pass a `:chat` config get them; everyone else implements their own.
    {chat_code, chat_overridable} = chat_ast(opts)

    quote do
      @behaviour Nous.Provider

      # Suppress dialyzer warnings for macro-generated functions that contain
      # pattern matches on provider IDs that can never match in a specific provider
      @dialyzer [
        {:nowarn_function, default_stream_normalizer: 0},
        {:nowarn_function, build_request_params: 3},
        {:nowarn_function, request: 3}
      ]

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
                  status_code: error_status(error),
                  retry_after_ms: Nous.Errors.RetryInfo.parse(error),
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
                has_tool_calls: length(parsed_response.tool_calls) > 0
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
                status_code: error_status(error),
                retry_after_ms: Nous.Errors.RetryInfo.parse(error),
                message: "Streaming request failed: #{inspect(error)}",
                details: error
              )

            {:error, wrapped_error}
        end
      end

      # Pull HTTP status from the standard backend error tuple shape.
      defp error_status(%{status: status}) when is_integer(status), do: status
      defp error_status(_), do: nil

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
        |> maybe_put("stop", merged_settings[:stop_sequences] || merged_settings[:stop])
        |> maybe_put("tools", merged_settings[:tools])
        |> maybe_put("tool_choice", merged_settings[:tool_choice])
        # OpenAI-style streaming usage opt-in (no-op on Anthropic/Gemini)
        |> maybe_put("stream_options", merged_settings[:stream_options])
        # Structured output: response_format
        |> maybe_put("response_format", merged_settings[:response_format])
        # vLLM guided decoding
        |> maybe_put("guided_json", merged_settings[:guided_json])
        |> maybe_put("guided_regex", merged_settings[:guided_regex])
        |> maybe_put("guided_grammar", merged_settings[:guided_grammar])
        |> maybe_put("guided_choice", merged_settings[:guided_choice])
        # SGLang guided decoding
        |> maybe_put("json_schema", merged_settings[:json_schema])
        |> maybe_put("regex", merged_settings[:regex])
        # Gemini
        |> maybe_put("generationConfig", merged_settings[:generationConfig])
        # Vendor-specific top-level body keys (vLLM/SGLang `top_k`,
        # `chat_template_kwargs`, etc.) — mirrors OpenAI Python SDK's `extra_body=`.
        |> maybe_merge_extra_body(merged_settings[:extra_body])
      end

      defp maybe_put(params, _key, nil), do: params
      defp maybe_put(params, key, value), do: Map.put(params, key, value)

      defp maybe_merge_extra_body(params, nil), do: params
      defp maybe_merge_extra_body(params, extra) when extra == %{}, do: params

      # Block top-level keys that would override safety / auth / routing fields.
      # `:extra_body` is for vendor-specific *additive* params (vLLM `top_k`,
      # `chat_template_kwargs`, etc.) - it must NOT be a back-door for
      # rewriting the conversation, the model, or the tool list.
      @blocked_extra_body_keys ~w(messages model stream system tools tool_choice)

      defp maybe_merge_extra_body(params, extra) when is_map(extra) do
        stringified = Map.new(extra, fn {k, v} -> {to_string(k), v} end)

        {dropped, allowed} =
          Map.split(
            stringified,
            Enum.filter(@blocked_extra_body_keys, &Map.has_key?(stringified, &1))
          )

        if map_size(dropped) > 0 do
          require Logger

          Logger.warning(
            ":extra_body contains blocked keys (#{inspect(Map.keys(dropped))}); dropping. " <>
              "Use the proper request fields for these instead."
          )
        end

        Map.merge(params, allowed)
      end

      # Defense-in-depth for non-map / non-nil values - log and pass through
      # without crashing the provider request pipeline.
      defp maybe_merge_extra_body(params, other) do
        require Logger
        Logger.warning(":extra_body must be a map, got: #{inspect(other)}; ignoring")
        params
      end

      # Default stream normalizer - providers can override
      defp default_stream_normalizer do
        case @provider_id do
          :anthropic -> Nous.StreamNormalizer.Anthropic
          :gemini -> Nous.StreamNormalizer.Gemini
          :vertex_ai -> Nous.StreamNormalizer.Gemini
          _ -> Nous.StreamNormalizer.OpenAI
        end
      end

      unquote(chat_code)

      defoverridable unquote(
                       [
                         count_tokens: 1,
                         request: 3,
                         request_stream: 3,
                         build_request_params: 3,
                         build_provider_opts: 1,
                         default_stream_normalizer: 0
                       ] ++ chat_overridable
                     )
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Shared OpenAI-compatible chat injection
  #
  # Many providers (vLLM, SGLang, LM Studio, Mistral, OpenAI-compatible, Custom)
  # speak the same OpenAI `/chat/completions` dialect. Their `chat/2` and
  # `chat_stream/2` bodies are identical except for three axes, all expressed
  # through the `:chat` option of `use Nous.Provider`:
  #
  #   * `:base_url` resolution strategy — `:plain | :local | :required`
  #   * `:headers` style — `:bearer | :bearer_org`
  #   * `:timeout` / `:stream_timeout` request timeouts
  #
  # Returns `{quoted_code, overridable_specs}` so the caller can both inject the
  # functions and mark them overridable.
  # ──────────────────────────────────────────────────────────────────────────
  @doc false
  def chat_ast(opts) do
    case Keyword.get(opts, :chat) do
      nil ->
        {nil, []}

      chat_opts ->
        id = Keyword.fetch!(opts, :id)
        timeout = Keyword.get(chat_opts, :timeout, 180_000)
        stream_timeout = Keyword.get(chat_opts, :stream_timeout, 300_000)
        base_strategy = Keyword.get(chat_opts, :base_url, :plain)
        header_style = Keyword.get(chat_opts, :headers, :bearer)
        display_name = Keyword.get(opts, :display_name) || default_display_name(id)
        base_env = base_url_env(id)

        resolver = resolve_base_url_ast(base_strategy, id, base_env, display_name)
        headers = build_headers_ast(header_style)

        ast =
          quote do
            @impl Nous.Provider
            def chat(params, opts \\ []) do
              with {:ok, base} <- chat_resolve_base_url(opts) do
                url = "#{base}/chat/completions"
                headers = chat_build_headers(api_key(opts), opts)
                timeout = Keyword.get(opts, :timeout, unquote(timeout))

                Nous.Providers.HTTP.post(url, params, headers, timeout: timeout)
              end
            end

            @impl Nous.Provider
            def chat_stream(params, opts \\ []) do
              with {:ok, base} <- chat_resolve_base_url(opts) do
                url = "#{base}/chat/completions"
                headers = chat_build_headers(api_key(opts), opts)
                timeout = Keyword.get(opts, :timeout, unquote(stream_timeout))
                finch_name = Keyword.get(opts, :finch_name, Nous.Finch)
                params = Map.put(params, "stream", true)

                Nous.Providers.HTTP.stream(url, params, headers,
                  timeout: timeout,
                  finch_name: finch_name
                )
              end
            end

            unquote(resolver)
            unquote(headers)
          end

        {ast, [chat: 2, chat_stream: 2]}
    end
  end

  # `:plain` — trust the resolved base URL as-is (used by hosted OpenAI-compatible
  # endpoints like Mistral that take an https URL). Never fails.
  defp resolve_base_url_ast(:plain, _id, _base_env, _display) do
    quote do
      defp chat_resolve_base_url(opts), do: {:ok, base_url(opts)}
    end
  end

  # `:local` — local-by-default servers (vLLM/SGLang/LM Studio). Reads a
  # `<PROVIDER>_BASE_URL` env override and validates through `UrlGuard` with
  # `allow_private_hosts: true` so localhost works but `file://` etc. is rejected.
  defp resolve_base_url_ast(:local, _id, base_env, display) do
    quote do
      defp chat_resolve_base_url(opts) do
        base =
          Keyword.get(opts, :base_url) ||
            System.get_env(unquote(base_env)) ||
            base_url(opts)

        case Nous.Tools.UrlGuard.validate(base, allow_private_hosts: true) do
          {:ok, _uri} ->
            {:ok, base}

          {:error, reason} ->
            {:error,
             {:invalid_config,
              unquote(display) <>
                " base_url failed validation: #{reason}. Got: #{inspect(base)}"}}
        end
      end
    end
  end

  # `:required` — user-supplied base URL is mandatory (Custom provider). Validated
  # through `UrlGuard` for SSRF protection; `allow_private_hosts` is opt-in via
  # opts or app config for local development.
  defp resolve_base_url_ast(:required, id, base_env, display) do
    quote do
      defp chat_resolve_base_url(opts) do
        base =
          Keyword.get(opts, :base_url) ||
            System.get_env(unquote(base_env)) ||
            get_in(Application.get_env(:nous, unquote(id), []), [:base_url])

        if is_nil(base) or base == "" do
          {:error,
           {:invalid_config,
            unquote(display) <>
              " requires a base_url. Set one of: " <>
              "Nous.new(\"#{unquote(id)}:model\", base_url: \"http://...\"), " <>
              unquote(base_env) <>
              " env var, or " <>
              "config :nous, #{inspect(unquote(id))}, base_url: \"http://...\""}}
        else
          allow_private =
            Keyword.get(opts, :allow_private_hosts) ||
              get_in(Application.get_env(:nous, unquote(id), []), [:allow_private_hosts]) ||
              false

          case Nous.Tools.UrlGuard.validate(base, allow_private_hosts: allow_private) do
            {:ok, _uri} ->
              {:ok, base}

            {:error, reason} ->
              {:error,
               {:invalid_config,
                unquote(display) <>
                  " base_url failed SSRF validation: #{reason}. " <>
                  "Set `allow_private_hosts: true` for local dev if intentional."}}
          end
        end
      end
    end
  end

  # `:bearer` — JSON + bearer token. `HTTP.bearer_auth_header/1` returns `[]` for
  # nil / empty / "not-needed", so the local-server "not-needed" sentinel is kept.
  defp build_headers_ast(:bearer) do
    quote do
      defp chat_build_headers(api_key, _opts) do
        Nous.Providers.HTTP.json_headers() ++ Nous.Providers.HTTP.bearer_auth_header(api_key)
      end
    end
  end

  # `:bearer_org` — adds the OpenAI `openai-organization` header when present.
  defp build_headers_ast(:bearer_org) do
    quote do
      defp chat_build_headers(api_key, opts) do
        Nous.Providers.HTTP.json_headers() ++
          Nous.Providers.HTTP.bearer_auth_header(api_key) ++
          Nous.Providers.HTTP.organization_header(Keyword.get(opts, :organization))
      end
    end
  end

  defp base_url_env(id), do: (id |> Atom.to_string() |> String.upcase()) <> "_BASE_URL"

  defp default_display_name(id), do: id |> Atom.to_string() |> String.capitalize()
end
