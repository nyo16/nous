if Code.ensure_loaded?(Floki) do
  defmodule Nous.Tools.WebFetch do
    @moduledoc """
    Tool for fetching and extracting readable content from web pages.

    Uses Req for HTTP and Floki for HTML parsing. Strips scripts, styles,
    and navigation to extract the main content.

    ## Dependencies

    Requires the `floki` package in your mix.exs:

        {:floki, "~> 0.36"}

    ## Usage

        agent = Agent.new("openai:gpt-4",
          tools: [&WebFetch.fetch_page/2]
        )
    """

    @doc """
    Fetch a web page and extract its readable content.

    ## Arguments

    - url: The URL to fetch (required)
    - selector: Optional CSS selector to extract specific content

    ## Returns

    A map with url, title, content, word_count, and fetched_at.
    """
    def fetch_page(_ctx, args) do
      url = Map.get(args, "url") || ""
      selector = Map.get(args, "selector")

      if url == "" do
        %{success: false, error: "URL is required"}
      else
        case do_fetch(url, selector) do
          {:ok, result} -> Map.put(result, :success, true)
          {:error, reason} -> %{success: false, error: reason, url: url}
        end
      end
    end

    @doc false
    def do_fetch(url, selector \\ nil) do
      with {:ok, body} <- fetch_url(url),
           {:ok, parsed} <- parse_html(body),
           content <- extract_content(parsed, selector) do
        title = extract_title(parsed)

        {:ok,
         %{
           url: url,
           title: title,
           content: content,
           word_count: content |> String.split(~r/\s+/) |> length(),
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
      end
    end

    defp fetch_url(url) do
      try do
        case Req.get(url,
               connect_options: [timeout: 10_000],
               receive_timeout: 15_000,
               max_redirects: 5,
               headers: [
                 {"user-agent",
                  "Mozilla/5.0 (compatible; NousBot/1.0; +https://github.com/nyo16/nous)"},
                 {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
               ]
             ) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
      rescue
        e -> {:error, "Request error: #{Exception.message(e)}"}
      end
    end

    defp parse_html(body) when is_binary(body) do
      case Floki.parse_document(body) do
        {:ok, doc} -> {:ok, doc}
        {:error, reason} -> {:error, "HTML parse error: #{inspect(reason)}"}
      end
    end

    defp parse_html(_), do: {:error, "Invalid response body"}

    defp extract_content(doc, selector) when is_list(doc) do
      # Remove script, style, nav, header, footer elements
      cleaned =
        doc
        |> remove_elements(["script", "style", "nav", "header", "footer", "aside", "noscript"])

      # Apply CSS selector if provided
      content_nodes =
        if selector do
          Floki.find(cleaned, selector)
        else
          # Try common content selectors
          find_main_content(cleaned)
        end

      content_nodes
      |> Floki.text(sep: " ")
      |> clean_text()
    end

    defp extract_content(text, _selector) when is_binary(text), do: clean_text(text)

    defp extract_title(doc) when is_list(doc) do
      case Floki.find(doc, "title") do
        [{_, _, children} | _] -> Floki.text([{nil, nil, children}]) |> String.trim()
        _ -> nil
      end
    end

    defp extract_title(_), do: nil

    defp find_main_content(doc) do
      # Try common content containers in order of specificity
      selectors = ["article", "main", "[role=main]", ".content", "#content", ".post", ".article"]

      Enum.find_value(selectors, doc, fn selector ->
        case Floki.find(doc, selector) do
          [] -> nil
          nodes -> nodes
        end
      end)
    end

    defp remove_elements(doc, tag_names) when is_list(doc) do
      Enum.reduce(tag_names, doc, fn tag, acc ->
        Floki.filter_out(acc, tag)
      end)
    end

    defp clean_text(text) do
      text
      |> String.replace(~r/\s+/, " ")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()
    end
  end
else
  defmodule Nous.Tools.WebFetch do
    @moduledoc """
    Tool for fetching and extracting readable content from web pages.

    Requires the `floki` package. Add `{:floki, "~> 0.36"}` to your deps.
    """

    def fetch_page(_ctx, _args) do
      %{success: false, error: "Floki is required. Add {:floki, \"~> 0.36\"} to your deps."}
    end

    @doc false
    def do_fetch(_url, _selector \\ nil) do
      {:error, "Floki is required. Add {:floki, \"~> 0.36\"} to your deps."}
    end
  end
end
