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
  - `chat/2` - Non-streaming chat completion
  - `chat_stream/2` - Streaming chat completion

  Optional:
  - `count_tokens/1` - Token counting (defaults to rough estimate)

  ## Injected Functions

  The `use` macro injects:
  - `provider_id/0` - Returns the provider atom ID
  - `default_base_url/0` - Returns the default API base URL
  - `default_env_key/0` - Returns the environment variable name for API key
  - `api_key/0` - Returns the API key from env or config
  - `base_url/1` - Returns base URL from opts, config, or default
  """

  @doc "Returns the provider identifier atom"
  @callback provider_id() :: atom()

  @doc "Returns the default API base URL"
  @callback default_base_url() :: String.t()

  @doc "Returns the environment variable name for the API key"
  @callback default_env_key() :: String.t()

  @doc """
  Make a non-streaming chat request.

  ## Parameters
    * `params` - Request parameters (model, messages, etc.)
    * `opts` - Options including :api_key, :base_url, :timeout

  ## Returns
    * `{:ok, response}` - Parsed response body
    * `{:error, reason}` - Error with reason
  """
  @callback chat(params :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Make a streaming chat request.

  ## Parameters
    * `params` - Request parameters (model, messages, etc.)
    * `opts` - Options including :api_key, :base_url, :timeout

  ## Returns
    * `{:ok, stream}` - Enumerable of parsed events
    * `{:error, reason}` - Error with reason
  """
  @callback chat_stream(params :: map(), opts :: keyword()) :: {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Count tokens in messages (can be an estimate).

  Optional callback - defaults to rough estimation if not implemented.
  """
  @callback count_tokens(messages :: list()) :: integer()

  @optional_callbacks count_tokens: 1

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

      defoverridable count_tokens: 1
    end
  end
end
