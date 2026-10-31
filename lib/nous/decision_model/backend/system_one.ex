defmodule Nous.DecisionModel.Backend.SystemOne do
  @moduledoc """
  HTTP backend for the TypeSafe-compatible **System One** API
  (`POST /v1/systemone`), plus a Cloudflare **Workers AI** preset.

  Servers: vLLM, SGLang (Clef), llama-server, Jev / OpenRouter, LiteLLM.

      # Self-hosted (vLLM, SGLang, llama-server)
      Nous.DecisionModel.parse("systemone:Cloudflare/clef-flash", base_url: "http://localhost:8000")

      # Cloudflare Workers AI (reads CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN)
      Nous.DecisionModel.parse("workers_ai:clef-flash")

  ## Wire format

  Request (key order is kept: questions and options are sent in the order
  declared, never re-sorted):

      {"model": "clef-flash",
       "state": ...,
       "questions": {"<id>": {"type": "noul", "instructions": "...",
                              "criteria": {"true": "...", "false": "..."}}}}

  No top-level `instructions` is ever sent: Clef-on-vLLM and Decision 3.0
  answer it with HTTP 400. Answers come back keyed by question id; Workers AI
  wraps them in its `{"result": ..., "success": true}` envelope, which is
  unwrapped.

  ## Options

    * `:base_url` - server root, e.g. `"http://localhost:8000"` (a trailing
      `/v1` is accepted). Required unless `preset: :workers_ai`, where it
      defaults to `"https://api.cloudflare.com/client/v4"`.
    * `:preset` - `:workers_ai` for Cloudflare Workers AI.
    * `:api_key` - bearer token. Workers AI default: `CLOUDFLARE_API_TOKEN`.
    * `:account_id` - Workers AI account. Default: `CLOUDFLARE_ACCOUNT_ID`.
    * `:timeout` - request timeout in ms. Default `5_000` (decisions are
      short; HTTP's 180 s default would stall a guard).
    * `:allow_private_hosts` - allow a private-network `base_url`. Loopback
      URLs (`localhost`, `127.0.0.1`, `::1`) are always allowed; any other URL
      goes through `Nous.UrlGuard`'s SSRF checks.
    * `:max_state_tokens` - token budget for state plus questions. Default
      65,536 for Workers AI, 16,384 otherwise (the self-hosted Clef
      reference). Servers truncate an over-long state silently, so callers
      should chunk before that.
    * `:http_backend` - a `Nous.HTTP.Backend` module for this backend's
      requests.

  ## Errors

    * 429 → `reason: :http`, `retryable?: true`, `retry_after_ms` from
      `Nous.Errors.RetryInfo`
    * 400 / 413 whose body says the request is too long → `:oversize`
    * other 4xx → `:http`; 5xx → `:http`, `retryable?: true`
    * transport timeout → `:timeout`; connection failures → `:unavailable`
    * a response with an undeclared id, option or level → `:unknown_label`

  vLLM's logprob-read models are batch-nondeterministic unless the server
  runs with `VLLM_BATCH_INVARIANT=1`; set it for security use.
  """

  @behaviour Nous.DecisionModel.Backend

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Backend, OrderedObject, Result, SystemOneWire}
  alias Nous.DecisionModel.Backend.HTTP, as: DecisionHTTP

  @workers_ai_base_url "https://api.cloudflare.com/client/v4"
  @path_segment ~r/\A[A-Za-z0-9._\-]+\z/

  @impl true
  def decide(%DecisionModel{opts: opts} = dm, state, questions, call_opts) do
    with {:ok, url, headers} <- endpoint(dm) do
      body =
        OrderedObject.new(
          maybe_model(dm.model) ++
            [{"state", state}, {"questions", SystemOneWire.encode_questions(questions)}]
        )

      with {:ok, response} <- DecisionHTTP.post(__MODULE__, url, body, headers, opts, call_opts),
           {:ok, payload} <- unwrap(response),
           {:ok, answers} <-
             SystemOneWire.decode_answers(payload["answers"], questions, __MODULE__) do
        {:ok,
         %Result{
           answers: answers,
           usage: SystemOneWire.usage(payload["usage"]),
           backend: __MODULE__,
           model: dm.model
         }}
      end
    end
  end

  @impl true
  def max_state_tokens(%DecisionModel{opts: opts}) do
    if Keyword.get(opts, :preset) == :workers_ai, do: 65_536, else: 16_384
  end

  defp maybe_model(nil), do: []
  defp maybe_model(model), do: [{"model", model}]

  defp endpoint(%DecisionModel{opts: opts} = dm) do
    case Keyword.get(opts, :preset) do
      :workers_ai -> workers_ai_endpoint(dm)
      nil -> systemone_endpoint(opts)
      other -> {:error, config_error("unknown SystemOne preset #{inspect(other)}")}
    end
  end

  defp systemone_endpoint(opts) do
    case Keyword.get(opts, :base_url) do
      base when is_binary(base) and base != "" ->
        {:ok, DecisionHTTP.root(base) <> "/v1/systemone", auth_headers(opts[:api_key])}

      _ ->
        {:error, config_error("systemone decision models require :base_url")}
    end
  end

  defp workers_ai_endpoint(%DecisionModel{model: model, opts: opts}) do
    account = Keyword.get(opts, :account_id) || System.get_env("CLOUDFLARE_ACCOUNT_ID")
    token = Keyword.get(opts, :api_key) || System.get_env("CLOUDFLARE_API_TOKEN")
    base = Keyword.get(opts, :base_url, @workers_ai_base_url)

    cond do
      not path_segment?(account) ->
        {:error, config_error("Workers AI needs CLOUDFLARE_ACCOUNT_ID (or :account_id)")}

      not (is_binary(token) and token != "") ->
        {:error, config_error("Workers AI needs CLOUDFLARE_API_TOKEN (or :api_key)")}

      not path_segment?(model) ->
        {:error, config_error("invalid Workers AI model #{inspect(model)}")}

      true ->
        url =
          String.trim_trailing(base, "/") <>
            "/accounts/#{account}/ai/run/@cf/cloudflare/#{model}"

        {:ok, url, auth_headers(token)}
    end
  end

  defp path_segment?(value), do: is_binary(value) and Regex.match?(@path_segment, value)

  defp auth_headers(token) when is_binary(token) and token != "",
    do: [{"authorization", "Bearer " <> token}]

  defp auth_headers(_), do: []

  # Workers AI REST responses: {"result": {...}, "success": true, ...}.
  defp unwrap(%{"result" => %{} = result}), do: {:ok, result}
  defp unwrap(%{"answers" => _} = payload), do: {:ok, payload}

  defp unwrap(other) do
    {:error,
     Backend.error(__MODULE__, :invalid_response, "no answers in response: #{inspect(other)}")}
  end

  defp config_error(message), do: Backend.error(__MODULE__, :unavailable, message)
end
