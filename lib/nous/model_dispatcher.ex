defmodule Nous.ModelDispatcher do
  @moduledoc """
  Dispatches model requests to the appropriate provider implementation.

  Routes requests to providers based on the model's provider field:
  - `:anthropic` → `Nous.Providers.Anthropic`
  - `:gemini` → `Nous.Providers.Gemini`
  - `:vertex_ai` → `Nous.Providers.VertexAI`
  - `:mistral` → `Nous.Providers.Mistral`
  - `:lmstudio` → `Nous.Providers.LMStudio`
  - `:llamacpp` → `Nous.Providers.LlamaCpp`
  - `:vllm` → `Nous.Providers.VLLM`
  - `:sglang` → `Nous.Providers.SGLang`
  - `:openai` → `Nous.Providers.OpenAI`
  - `:custom` → `Nous.Providers.Custom`
  - Others → `Nous.Providers.OpenAICompatible`

  ## Swapping the dispatcher

  Every model request in Nous goes through a *resolved* dispatcher module
  rather than through this module directly. See `resolve/1` for the precedence
  rules, `config :nous, :model_dispatcher, MyDispatcher` for the production
  injection point, and `put_dispatcher/1` for the process-scoped testing seam.
  """

  alias Nous.{Model, Providers}

  require Logger

  # Process-dictionary key for the process-scoped override installed by
  # `put_dispatcher/1`. The `$nous_` prefix keeps it out of collision range of
  # both user keys and OTP's own `$`-prefixed entries.
  @override_key :"$nous_model_dispatcher"

  @provider_modules %{
    anthropic: Providers.Anthropic,
    gemini: Providers.Gemini,
    vertex_ai: Providers.VertexAI,
    mistral: Providers.Mistral,
    lmstudio: Providers.LMStudio,
    llamacpp: Providers.LlamaCpp,
    vllm: Providers.VLLM,
    sglang: Providers.SGLang,
    openai: Providers.OpenAI,
    custom: Providers.Custom
  }

  @doc """
  Resolve the provider module for a provider atom.

  Unknown providers fall back to `Nous.Providers.OpenAICompatible`.
  """
  @spec provider_module(atom()) :: module()
  def provider_module(provider) do
    Map.get(@provider_modules, provider, Providers.OpenAICompatible)
  end

  @doc """
  Install a process-scoped dispatcher override. **Testing seam only.**

  Unlike `config :nous, :model_dispatcher, MyDispatcher` — which remains the
  production mechanism — this writes no global state. The module is stored in
  the calling process's dictionary and is visible to that process and to any
  process that lists it in `$callers`; `Task.async/1`, `Task.async_stream/3`
  and `Task.Supervisor.async/2` all propagate `$callers`, so work the runner
  fans out still sees the override. Concurrent (`async: true`) test modules can
  therefore each install their own stub without contending for the application
  environment.

  The override lives and dies with the calling process. ExUnit gives every test
  a fresh one, so there is nothing to tear down; pass `nil` to clear it early.

  `$callers` is *not* propagated across `GenServer.start_link/3`, so a run
  driven through `Nous.AgentServer` executes in the server process and will not
  see the override. Those tests still need the application environment, and
  must stay `async: false` because of it.

      test "retries on a provider error" do
        Nous.ModelDispatcher.put_dispatcher(FlakyDispatcher)
        assert {:ok, _} = Nous.generate_text("openai:gpt-4", "hi")
      end

  """
  @spec put_dispatcher(module() | nil) :: :ok
  def put_dispatcher(nil) do
    Process.delete(@override_key)
    :ok
  end

  def put_dispatcher(module) when is_atom(module) do
    Process.put(@override_key, module)
    :ok
  end

  @doc """
  Resolve the module that services model requests, highest precedence first:

    1. `override` — an explicit per-call module, such as `Nous.LLM`'s
      `:model_dispatcher` option. `nil` means "not specified".
    2. A process-scoped override from `put_dispatcher/1`, searched in the
      calling process and then along `$callers`.
    3. `config :nous, :model_dispatcher, MyDispatcher`.
    4. `Nous.ModelDispatcher`.

  """
  @spec resolve(module() | nil) :: module()
  def resolve(override \\ nil)

  def resolve(nil) do
    process_override() || Application.get_env(:nous, :model_dispatcher, __MODULE__)
  end

  def resolve(module) when is_atom(module), do: module

  defp process_override do
    case Process.get(@override_key) do
      nil -> callers_override(Process.get(:"$callers", []))
      module -> module
    end
  end

  # Nothing to walk in the overwhelmingly common case, so production pays two
  # process-dictionary reads and stops here.
  defp callers_override([]), do: nil
  defp callers_override(callers), do: Enum.find_value(callers, &caller_override/1)

  # `process_info(pid, {:dictionary, key})` fetches one entry instead of
  # copying the whole dictionary out of the other process. It landed in OTP 26;
  # `elixir ~> 1.18` still supports OTP 25, so keep the copying form for it.
  if String.to_integer(System.otp_release()) >= 26 do
    defp caller_override(pid) do
      case :erlang.process_info(pid, {:dictionary, @override_key}) do
        {_key, module} when is_atom(module) and module != :undefined -> module
        _ -> nil
      end
    end
  else
    defp caller_override(pid) do
      case :erlang.process_info(pid, :dictionary) do
        {:dictionary, dict} -> :proplists.get_value(@override_key, dict, nil)
        _ -> nil
      end
    end
  end

  @doc """
  Dispatch request to the appropriate provider implementation.
  """
  @spec request(Model.t(), list(), map()) :: {:ok, map()} | {:error, term()}
  def request(%Model{} = model, messages, settings) do
    provider = provider_module(model.provider)
    Logger.debug("Routing to #{inspect(provider)} for: #{model.provider}:#{model.model}")
    provider.request(model, messages, settings)
  end

  @doc """
  Dispatch streaming request to the appropriate provider implementation.
  """
  @spec request_stream(Model.t(), list(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def request_stream(%Model{} = model, messages, settings) do
    provider = provider_module(model.provider)

    Logger.debug(
      "Routing streaming request to #{inspect(provider)} for: #{model.provider}:#{model.model}"
    )

    provider.request_stream(model, messages, settings)
  end

  @doc """
  Count tokens (uses appropriate provider implementation).
  """
  @spec count_tokens(Model.t(), list()) :: integer()
  def count_tokens(%Model{} = model, messages) do
    provider_module(model.provider).count_tokens(messages)
  end
end
