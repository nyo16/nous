defmodule Nous.Errors.RetryInfo do
  @moduledoc """
  Parse server-suggested retry delays from provider error responses.

  Two sources are checked, body first then headers:

  1. **Body** — Google APIs (Vertex AI, Gemini) embed
     `google.rpc.RetryInfo` inside `error.details[]` with a
     `retryDelay` field as a `google.protobuf.Duration` string
     (e.g. `"34s"`, `"1.500s"`).
  2. **Headers** — Standard HTTP `Retry-After` (RFC 7231). Integer
     seconds is supported; HTTP-date form is intentionally not handled
     here as no LLM provider in production uses it for rate limits.

  Returns the suggested delay in **milliseconds**, or `nil` when no
  hint is available. A missing hint is itself meaningful for Google
  APIs — daily/long-term quota exhaustion deliberately omits
  `RetryInfo` to discourage retry loops, so callers should treat
  `nil` as "do not auto-retry".
  """

  @retry_info_type "type.googleapis.com/google.rpc.RetryInfo"

  @doc """
  Extract a retry delay (ms) from an HTTP error tuple's payload.

  Accepts the shape produced by `Nous.HTTP.Backend` implementations:
  `%{status: integer, body: term, headers: list}`. Missing fields are
  tolerated.

  ## Examples

      iex> RetryInfo.parse(%{
      ...>   status: 429,
      ...>   body: %{"error" => %{"details" => [
      ...>     %{"@type" => "type.googleapis.com/google.rpc.RetryInfo",
      ...>       "retryDelay" => "34s"}
      ...>   ]}}
      ...> })
      34_000

      iex> RetryInfo.parse(%{status: 429, headers: [{"retry-after", "60"}]})
      60_000

      iex> RetryInfo.parse(%{status: 429, body: %{"error" => %{"message" => "rate limited"}}})
      nil
  """
  @spec parse(any()) :: pos_integer() | nil
  def parse(%{} = error) do
    body = Map.get(error, :body)
    headers = Map.get(error, :headers, [])

    from_body(body) || from_headers(headers)
  end

  def parse(_), do: nil

  # ---------------------------------------------------------------------------
  # Body: google.rpc.RetryInfo inside error.details[]

  defp from_body(%{"error" => %{"details" => details}}) when is_list(details) do
    Enum.find_value(details, fn
      %{"@type" => @retry_info_type, "retryDelay" => delay} -> parse_duration(delay)
      _ -> nil
    end)
  end

  defp from_body(_), do: nil

  # google.protobuf.Duration: "<seconds>s" — int or fractional.
  defp parse_duration(s) when is_binary(s) do
    case Float.parse(s) do
      {seconds, "s"} when seconds > 0 -> trunc(seconds * 1000)
      _ -> nil
    end
  end

  defp parse_duration(_), do: nil

  # ---------------------------------------------------------------------------
  # Headers: Retry-After (case-insensitive)

  defp from_headers(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} ->
        if to_string(k) |> String.downcase() == "retry-after" do
          parse_retry_after(to_string(v))
        end

      _ ->
        nil
    end)
  end

  defp from_headers(_), do: nil

  defp parse_retry_after(s) do
    case Integer.parse(s) do
      {seconds, ""} when seconds > 0 -> seconds * 1000
      _ -> nil
    end
  end
end
