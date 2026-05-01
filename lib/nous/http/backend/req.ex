defmodule Nous.HTTP.Backend.Req do
  @moduledoc """
  `Nous.HTTP.Backend` implementation backed by `Req` (which uses `Finch`
  under the hood).

  The default backend — picks up the existing `Req`/`Finch` pool that is
  already in the dependency tree, supports redirects, retries, and the
  rest of the Req middleware chain. See `Nous.HTTP.Backend` for how to
  switch to the hackney backend.
  """

  @behaviour Nous.HTTP.Backend

  require Logger

  # 3 minutes — LLMs with reasoning/long completions routinely exceed
  # the previous 60s default. Per-call `:timeout` opt overrides.
  @default_timeout 180_000

  @impl Nous.HTTP.Backend
  def post(url, body, headers, opts \\ [])
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    finch_name = Keyword.get(opts, :finch_name) || Application.get_env(:nous, :finch, Nous.Finch)

    # Note: Req disallows both `:finch` and `:connect_options` — connect
    # timeouts are pool-level when using a named Finch pool. If callers
    # need a custom connect timeout, configure it on the Finch pool
    # itself (`Nous.Application` starts `Nous.Finch`).
    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: timeout,
           finch: finch_name
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning(
          "HTTP request failed with status #{status}: #{truncate_for_log(response_body)}"
        )

        {:error, %{status: status, body: response_body}}

      {:error, %Mint.TransportError{reason: reason} = error} ->
        Logger.error("Transport error: #{inspect(reason)}")
        {:error, error}

      {:error, error} ->
        Logger.error("HTTP request error: #{inspect(error)}")
        {:error, error}
    end
  end

  defp truncate_for_log(data) when is_binary(data) do
    if byte_size(data) > 500 do
      String.slice(data, 0, 500) <> "... (truncated)"
    else
      data
    end
  end

  defp truncate_for_log(data), do: inspect(data, limit: 500)
end
