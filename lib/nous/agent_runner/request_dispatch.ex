defmodule Nous.AgentRunner.RequestDispatch do
  @moduledoc false
  # Model request dispatch for Nous.AgentRunner: fallback-chain requests
  # (plain and streaming), team rate-limiter acquire/record/release, and
  # provider-specific settings/tool-schema rebuilding. Internal to the runner.

  alias Nous.{Fallback, ModelDispatcher, Tool}
  alias Nous.AgentRunner.{PromptAssembly, Streaming}

  require Logger

  # Request with fallback chain support.
  # When fallback models are configured, tries each model in order on eligible errors.
  # Returns {:ok, response, active_model} or {:error, reason}.
  def request_with_fallback(agent, messages, model_settings, all_tools) do
    model_chain = Fallback.build_model_chain(agent.model, agent.fallback)

    Fallback.with_fallback(model_chain, fn model ->
      # Re-convert tool schemas if provider changed
      settings = rebuild_settings_for_model(model, model_settings, all_tools, agent)

      case get_dispatcher().request(model, messages, settings) do
        {:ok, response} -> {:ok, {response, model}}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, {response, active_model}} -> {:ok, response, active_model}
      {:error, _} = err -> err
    end
  end

  # Stream with fallback chain support.
  # Only retries stream initialization, not mid-stream failures.
  def stream_with_fallback(agent, messages, model_settings, tools) do
    model_chain = Fallback.build_model_chain(agent.model, agent.fallback)

    Fallback.with_fallback(model_chain, fn model ->
      settings = rebuild_settings_for_model(model, model_settings, tools, agent)
      get_dispatcher().request_stream(model, messages, settings)
    end)
  end

  # Streaming counterpart to request_with_fallback/4. Initializes the stream
  # via stream_with_fallback/4 (so initialization errors trigger fallback),
  # then consumes the stream eagerly into a %Nous.Message{} structurally
  # identical to what request_with_fallback/4 returns. Per-chunk delta
  # callbacks fire from the consumer, and the assembled message flows back
  # into the same do_iteration code path that handles tool calls and the
  # next iteration.
  #
  # Returns {:ok, response, active_model} or {:error, reason}.
  @openai_compat_providers ~w(openai custom vllm sglang lmstudio llamacpp)a

  def stream_request_with_fallback(agent, messages, model_settings, all_tools, ctx) do
    model_chain = Fallback.build_model_chain(agent.model, agent.fallback)

    Fallback.with_fallback(model_chain, fn model ->
      settings =
        model
        |> rebuild_settings_for_model(model_settings, all_tools, agent)
        |> maybe_inject_include_usage(model.provider)

      with {:ok, stream} <- get_dispatcher().request_stream(model, messages, settings),
           {:ok, message} <- Streaming.consume_stream_into_message(stream, ctx, model.provider) do
        {:ok, {message, model}}
      end
    end)
    |> case do
      {:ok, {response, active_model}} -> {:ok, response, active_model}
      {:error, _} = err -> err
    end
  end

  def maybe_inject_include_usage(settings, provider)
      when provider in @openai_compat_providers do
    current = Map.get(settings, :stream_options) || %{}
    Map.put(settings, :stream_options, Map.put(current, :include_usage, true))
  end

  def maybe_inject_include_usage(settings, _provider), do: settings

  # --- Rate limiting (team agents) ---------------------------------------------

  def acquire_and_request(nil, _agent, _messages, request_fun), do: request_fun.()

  def acquire_and_request(pid, agent, messages, request_fun) do
    tokens = estimate_request_tokens(messages)

    case safe_acquire(pid, agent.name, tokens) do
      {:ok, ref} ->
        result = request_fun.()
        record_or_release_rate_limit(pid, agent.name, ref, result)
        result

      {:error, :rate_limiter_unavailable} ->
        # The limiter died between resolution and acquire (or is overloaded and
        # timed out). Fail OPEN — skipping a rate check is far better than
        # crashing the whole agent run on a {:noproc, _}/timeout exit. Surface it
        # though: a silent fail-open would let a dead limiter allow unlimited
        # traffic with no signal until cost/token metrics spiked.
        Logger.warning(
          "RateLimiter unavailable for agent #{inspect(agent.name)}; failing open (request not rate-limited)"
        )

        :telemetry.execute([:nous, :rate_limiter, :unavailable], %{count: 1}, %{
          agent: agent.name
        })

        request_fun.()

      {:error, _reason} = err ->
        err
    end
  end

  # The resolved limiter pid can die before/while we call it (TOCTOU). Catch the
  # exit instead of leaking a {:noproc, _}/timeout into the agent loop.
  def safe_acquire(pid, name, tokens) do
    Nous.Teams.RateLimiter.acquire(pid, name, tokens)
  catch
    :exit, _ -> {:error, :rate_limiter_unavailable}
  end

  def record_or_release_rate_limit(pid, name, ref, {:ok, response, _model}) do
    usage = (response.metadata && response.metadata.usage) || %{}
    tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    Nous.Teams.RateLimiter.record_usage(pid, name, %{tokens: tokens, cost: 0.0, reservation: ref})
  end

  def record_or_release_rate_limit(pid, _name, ref, _other) do
    Nous.Teams.RateLimiter.release(pid, ref)
  end

  def resolve_rate_limiter(ctx) do
    resolve_alive_process(ctx.deps[:rate_limiter_pid])
  end

  # No Process.alive?/1 pre-check: it only narrows — never closes — the race
  # before acquire, and a stale `true` is indistinguishable from a live pid. The
  # authoritative guard is safe_acquire/3, which catches the exit if the pid is
  # already dead. Here we just resolve a name to its currently-registered pid.
  def resolve_alive_process(pid) when is_pid(pid), do: pid

  def resolve_alive_process(name) when is_atom(name) and not is_nil(name) do
    GenServer.whereis(name)
  end

  def resolve_alive_process(_), do: nil

  # Rough input-token estimate (≈4 chars/token) for the pre-call reservation;
  # reconciled to actual usage by record_usage after the response.
  def estimate_request_tokens(messages) do
    chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        # Only binary content contributes to the rough estimate; a message with
        # nil content (tool-call-only) or list content (multimodal) is skipped
        # rather than crashing Message.extract_text/1 (no nil clause).
        text = if is_binary(msg.content), do: msg.content, else: ""
        acc + byte_size(text)
      end)

    max(div(chars, 4), 1)
  end

  # Rebuild model settings when falling back to a different provider.
  # Tool schemas must be re-converted for the target provider's format.
  def rebuild_settings_for_model(model, model_settings, all_tools, agent) do
    if model.provider == agent.model.provider do
      model_settings
    else
      # Strip existing tool schemas and re-convert for the new provider
      base_settings =
        model_settings
        |> Map.delete(:tools)
        |> Map.delete(:tool_choice)
        |> Map.delete(:response_format)

      settings =
        if Enum.empty?(all_tools) do
          base_settings
        else
          tool_schemas = convert_tools_for_provider(model.provider, all_tools)
          Map.put(base_settings, :tools, tool_schemas)
        end

      # Re-inject structured output settings for the new provider if needed
      if agent.output_type != :string do
        # Use a temporary agent with the fallback model so provider-specific settings are correct
        PromptAssembly.inject_structured_output_settings(
          %{agent | model: model},
          settings,
          all_tools
        )
      else
        settings
      end
    end
  end

  # Get the model dispatcher, allowing dependency injection for testing
  def get_dispatcher do
    Application.get_env(:nous, :model_dispatcher, ModelDispatcher)
  end

  # Convert tools to provider-specific format
  def convert_tools_for_provider(:anthropic, tools) do
    # Anthropic uses atom keys and different format
    Enum.map(tools, &Nous.ToolSchema.to_anthropic/1)
  end

  def convert_tools_for_provider(_, tools) do
    # OpenAI-compatible providers use string keys
    Enum.map(tools, &Tool.to_openai_schema/1)
  end
end
