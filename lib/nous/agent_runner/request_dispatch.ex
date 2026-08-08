defmodule Nous.AgentRunner.RequestDispatch do
  @moduledoc false
  # Model request dispatch for Nous.AgentRunner: fallback-chain requests
  # (plain and streaming), team rate-limiter acquire/record/release, and
  # provider-specific settings/tool-schema rebuilding. Internal to the runner.

  alias Nous.{Fallback, Message, Model, ModelDispatcher, Tool}
  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.AgentRunner.{PromptAssembly, Streaming}
  alias Nous.Teams.RateLimiter

  require Logger

  # A completed (or failed) model request. The active model rides along so a
  # fallback promotion stays visible to the caller.
  @type request_result :: {:ok, Message.t(), Model.t()} | {:error, term()}

  # Request with fallback chain support.
  # When fallback models are configured, tries each model in order on eligible errors.
  # Returns {:ok, response, active_model} or {:error, reason}.
  @spec request_with_fallback(Agent.t(), [Message.t()], map(), [Tool.t()]) :: request_result()
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
  @spec stream_with_fallback(Agent.t(), [Message.t()], map(), [Tool.t()]) ::
          {:ok, Enumerable.t()} | {:error, term()}
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

  @spec stream_request_with_fallback(Agent.t(), [Message.t()], map(), [Tool.t()], Context.t()) ::
          request_result()
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

  @spec maybe_inject_include_usage(map(), Model.provider()) :: map()
  def maybe_inject_include_usage(settings, provider)
      when provider in @openai_compat_providers do
    current = Map.get(settings, :stream_options) || %{}
    Map.put(settings, :stream_options, Map.put(current, :include_usage, true))
  end

  def maybe_inject_include_usage(settings, _provider), do: settings

  # --- Rate limiting (team agents) ---------------------------------------------

  @spec acquire_and_request(pid() | nil, Agent.t(), [Message.t()], (-> request_result())) ::
          request_result()
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
  @spec safe_acquire(pid(), String.t(), non_neg_integer()) ::
          {:ok, RateLimiter.reservation_ref()}
          | {:error, :budget_exceeded | :rate_limited | :rate_limiter_unavailable}
  def safe_acquire(pid, name, tokens) do
    RateLimiter.acquire(pid, name, tokens)
  catch
    :exit, _ -> {:error, :rate_limiter_unavailable}
  end

  @spec record_or_release_rate_limit(
          pid(),
          String.t(),
          RateLimiter.reservation_ref(),
          request_result()
        ) :: :ok
  def record_or_release_rate_limit(pid, name, ref, {:ok, response, _model}) do
    usage = (response.metadata && response.metadata.usage) || %{}
    tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    RateLimiter.record_usage(pid, name, %{tokens: tokens, cost: 0.0, reservation: ref})
  end

  def record_or_release_rate_limit(pid, _name, ref, _other) do
    RateLimiter.release(pid, ref)
  end

  @spec resolve_rate_limiter(Context.t()) :: pid() | nil
  def resolve_rate_limiter(ctx) do
    resolve_alive_process(ctx.deps[:rate_limiter_pid])
  end

  # No Process.alive?/1 pre-check: it only narrows — never closes — the race
  # before acquire, and a stale `true` is indistinguishable from a live pid. The
  # authoritative guard is safe_acquire/3, which catches the exit if the pid is
  # already dead. Here we just resolve a name to its currently-registered pid.
  @spec resolve_alive_process(term()) :: pid() | nil
  def resolve_alive_process(pid) when is_pid(pid), do: pid

  def resolve_alive_process(name) when is_atom(name) and not is_nil(name) do
    GenServer.whereis(name)
  end

  def resolve_alive_process(_), do: nil

  # Rough input-token estimate (≈4 chars/token) for the pre-call reservation;
  # reconciled to actual usage by record_usage after the response.
  @spec estimate_request_tokens([Message.t()]) :: pos_integer()
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
  @spec rebuild_settings_for_model(Model.t(), map(), [Tool.t()], Agent.t()) :: map()
  def rebuild_settings_for_model(model, model_settings, all_tools, agent) do
    if model.provider == agent.model.provider do
      model_settings
    else
      settings =
        rebuild_tool_settings(model.provider, agent.model.provider, model_settings, all_tools)

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

  # Strip the previous provider's tool settings and re-convert the tool schemas
  # for `target_provider`. Split out of rebuild_settings_for_model/4 so
  # `Nous.LLM` — which runs the same fallback-across-providers path but has no
  # %Agent{} and therefore no structured-output stage — can share it instead of
  # keeping the divergent private copy the arch review found.
  @spec rebuild_tool_settings(Model.provider(), Model.provider(), map(), [Tool.t()]) :: map()
  def rebuild_tool_settings(provider, provider, model_settings, _all_tools), do: model_settings

  def rebuild_tool_settings(target_provider, _source_provider, model_settings, all_tools) do
    base_settings =
      model_settings
      |> Map.delete(:tools)
      |> Map.delete(:tool_choice)
      |> Map.delete(:response_format)

    if Enum.empty?(all_tools) do
      base_settings
    else
      Map.put(base_settings, :tools, convert_tools_for_provider(target_provider, all_tools))
    end
  end

  # Resolve the model dispatcher. The runner has no per-call override to thread
  # (agents carry no dispatcher field), so this is the process-override →
  # app-env → default chain. See `Nous.ModelDispatcher.resolve/1`.
  @spec get_dispatcher() :: module()
  def get_dispatcher, do: ModelDispatcher.resolve()

  # Convert tools to provider-specific format
  @spec convert_tools_for_provider(Model.provider(), [Tool.t()]) :: [map()]
  def convert_tools_for_provider(:anthropic, tools) do
    # Anthropic uses atom keys and different format
    Enum.map(tools, &Nous.Tool.Wire.to_anthropic/1)
  end

  # Gemini/Vertex take BARE function declarations, not OpenAI's
  # %{"type" => "function", "function" => …} envelope: Nous.Messages.Gemini
  # drops this list straight into %{"functionDeclarations" => list}
  # (messages/gemini.ex:481). Falling through to the OpenAI clause below shipped
  # a malformed declaration on every agent-path Gemini/Vertex call with tools.
  # Nous.LLM carried the correct clause; this side was the bug (arch-review:
  # "Nous.LLM re-implements the runner's tool loop and has DIVERGED").
  def convert_tools_for_provider(provider, tools) when provider in [:vertex_ai, :gemini] do
    Enum.map(tools, &Nous.Tool.Wire.to_gemini/1)
  end

  def convert_tools_for_provider(_, tools) do
    # OpenAI-compatible providers use string keys
    Enum.map(tools, &Tool.to_openai_schema/1)
  end
end
