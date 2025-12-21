defmodule DeepResearch.Tools.ContentTools do
  @moduledoc """
  Tools for fetching and extracting content from URLs.
  """

  require Logger

  @max_content_length 10_000
  @timeout 15_000

  @doc """
  Fetch content from a URL.

  ## Parameters
  - url: The URL to fetch (required)
  - max_length: Maximum content length to return (default: 10000)

  ## Returns
  Extracted text content from the page.
  """
  def fetch_url(_ctx, args) do
    url = Map.get(args, "url", "")
    max_length = Map.get(args, "max_length", @max_content_length)

    if url == "" do
      %{success: false, error: "url is required"}
    else
      perform_fetch(url, max_length)
    end
  end

  @doc """
  Fetch and summarize content from a URL.

  ## Parameters
  - url: The URL to fetch (required)
  - focus: What aspect to focus on (optional)

  Returns content with extraction hints for the LLM.
  """
  def fetch_and_extract(_ctx, args) do
    url = Map.get(args, "url", "")
    focus = Map.get(args, "focus", "main content")

    if url == "" do
      %{success: false, error: "url is required"}
    else
      case perform_fetch(url, @max_content_length) do
        %{success: true, content: content} = result ->
          Map.merge(result, %{
            extraction_hints: """
            Focus on extracting: #{focus}

            Look for:
            - Key facts and statistics
            - Main arguments or claims
            - Important dates or timelines
            - Named entities (people, organizations, places)
            - Conclusions or recommendations
            """,
            content_preview: String.slice(content, 0..500)
          })

        error ->
          error
      end
    end
  end

  @doc """
  Extract structured information from content.

  ## Parameters
  - content: Text content to analyze (required)
  - extract_type: What to extract - entities/facts/dates/all (default: all)

  Note: This provides guidance for LLM extraction rather than doing NLP.
  """
  def extract_info(_ctx, args) do
    content = Map.get(args, "content", "")
    extract_type = Map.get(args, "extract_type", "all")

    if content == "" do
      %{success: false, error: "content is required"}
    else
      %{
        success: true,
        content_length: String.length(content),
        extraction_guidance: extraction_guidance(extract_type),
        sample: String.slice(content, 0..300)
      }
    end
  end

  # Private functions

  defp perform_fetch(url, max_length) do
    headers = [
      {~c"User-Agent",
       ~c"Mozilla/5.0 (compatible; DeepResearchBot/1.0; +https://github.com/nyo16/nous)"},
      {~c"Accept", ~c"text/html,application/xhtml+xml,text/plain"}
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(url), headers},
           [timeout: @timeout, autoredirect: true],
           []
         ) do
      {:ok, {{_, 200, _}, response_headers, body}} ->
        content_type = get_content_type(response_headers)
        content = extract_text_content(to_string(body), content_type)
        truncated = String.slice(content, 0, max_length)

        %{
          success: true,
          url: url,
          content: truncated,
          content_length: String.length(truncated),
          full_length: String.length(content),
          truncated: String.length(content) > max_length,
          content_type: content_type,
          fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

      {:ok, {{_, status, _}, _, body}} when status in 301..399 ->
        # Handle redirect manually if needed
        %{
          success: false,
          error: "Redirect (#{status})",
          url: url,
          body_preview: to_string(body) |> String.slice(0..200)
        }

      {:ok, {{_, status, _}, _, body}} ->
        %{
          success: false,
          error: "HTTP #{status}",
          url: url,
          body_preview: to_string(body) |> String.slice(0..200)
        }

      {:error, reason} ->
        Logger.warning("Failed to fetch #{url}: #{inspect(reason)}")
        %{success: false, error: "Fetch failed: #{inspect(reason)}", url: url}
    end
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {k, _v} ->
      String.downcase(to_string(k)) == "content-type"
    end)
    |> case do
      {_, v} -> to_string(v) |> String.split(";") |> List.first() |> String.trim()
      nil -> "text/html"
    end
  end

  defp extract_text_content(html, content_type) do
    case content_type do
      "text/plain" ->
        html

      _ ->
        html
        # Remove script and style content
        |> String.replace(~r/<script[^>]*>.*?<\/script>/si, " ")
        |> String.replace(~r/<style[^>]*>.*?<\/style>/si, " ")
        |> String.replace(~r/<noscript[^>]*>.*?<\/noscript>/si, " ")
        # Remove HTML comments
        |> String.replace(~r/<!--.*?-->/s, " ")
        # Remove all HTML tags
        |> String.replace(~r/<[^>]+>/, " ")
        # Decode common HTML entities
        |> decode_html_entities()
        # Normalize whitespace
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
    end
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&apos;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&ndash;", "-")
    |> String.replace("&mdash;", "-")
    |> String.replace("&hellip;", "...")
  end

  defp extraction_guidance("entities") do
    """
    Extract named entities:
    - People: Names of individuals mentioned
    - Organizations: Companies, institutions, groups
    - Places: Locations, countries, cities
    - Products: Software, technologies, products
    """
  end

  defp extraction_guidance("facts") do
    """
    Extract key facts:
    - Statistics and numbers
    - Claims with evidence
    - Definitions and explanations
    - Cause and effect relationships
    """
  end

  defp extraction_guidance("dates") do
    """
    Extract temporal information:
    - Specific dates and times
    - Time periods and durations
    - Sequences of events
    - Deadlines and milestones
    """
  end

  defp extraction_guidance(_all) do
    """
    Extract all key information:
    1. Named entities (people, organizations, places)
    2. Key facts and statistics
    3. Main arguments and claims
    4. Dates and timelines
    5. Relationships between concepts
    """
  end
end
