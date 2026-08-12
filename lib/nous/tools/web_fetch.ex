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

    ## Limits

    A fetch buffers at most 5_000_000 bytes and refuses anything whose
    `content-type` is not `text/html`, `application/xhtml+xml`, or
    `text/plain` — the URL comes from the model, and the extractor only
    understands markup. Move the ceiling with `ctx.deps[:web_fetch_max_bytes]`
    or `config :nous, web_fetch_max_bytes: bytes`; a `max_bytes` tool argument
    may only lower it, never raise it.
    """

    # Ceiling on the response body we are willing to buffer, in bytes. The URL
    # is model-controlled, so an uncapped fetch of a multi-gigabyte file (or of
    # an endpoint that never stops sending) would take the node down with it.
    @default_max_bytes 5_000_000

    # The extractor only understands markup. Anything else (PDF, image,
    # tarball, JSON) is rejected before it reaches Floki. Compared against the
    # bare media type, with any `; charset=...` parameters stripped.
    @allowed_content_types ~w(text/html application/xhtml+xml text/plain)

    @doc """
    Fetch a web page and extract its readable content.

    ## Arguments

    - url: The URL to fetch (required)
    - selector: Optional CSS selector to extract specific content
    - max_bytes: Optional cap on the response body, in bytes. May only lower
      the host-configured ceiling (see `do_fetch/3`), never raise it.

    ## Returns

    A map with url, title, content, word_count, and fetched_at.
    """
    @spec fetch_page(Nous.RunContext.t(), map()) :: map()
    def fetch_page(ctx, args) do
      url = Map.get(args, "url") || ""
      selector = Map.get(args, "selector")

      if url == "" do
        %{success: false, error: "URL is required"}
      else
        case do_fetch(url, selector, max_bytes: resolve_max_bytes(ctx, args)) do
          {:ok, result} -> Map.put(result, :success, true)
          {:error, reason} -> %{success: false, error: reason, url: url}
        end
      end
    end

    # `:max_bytes` in `opts` overrides the default response ceiling.
    @doc false
    @spec do_fetch(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, String.t()}
    def do_fetch(url, selector \\ nil, opts \\ []) do
      with {:ok, body} <- fetch_url(url, Keyword.get(opts, :max_bytes, @default_max_bytes)),
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

    # Option resolution follows `Nous.Tools.Search.Common.api_key/3`: context
    # deps first, then application config. The resolved value is a *ceiling*:
    # `args` come from the model, so an explicit "max_bytes" arg may only lower
    # it. Otherwise the model could simply ask for the OOM back.
    defp resolve_max_bytes(ctx, args) do
      ceiling =
        positive_int(ctx_deps(ctx)[:web_fetch_max_bytes]) ||
          positive_int(Application.get_env(:nous, :web_fetch_max_bytes)) ||
          @default_max_bytes

      case positive_int(Map.get(args, "max_bytes")) do
        nil -> ceiling
        requested -> min(requested, ceiling)
      end
    end

    defp ctx_deps(%{deps: deps}) when is_map(deps), do: deps
    defp ctx_deps(_ctx), do: %{}

    defp positive_int(n) when is_integer(n) and n > 0, do: n

    defp positive_int(s) when is_binary(s) do
      case Integer.parse(s) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end
    end

    defp positive_int(_other), do: nil

    defp fetch_url(url, max_bytes) do
      try do
        # max_redirects: 0 - we follow manually because Req's automatic follow
        # does NOT re-validate the redirect target, leaving an SSRF-via-public-
        # bounce hole. do_get/3 validates AND pins every hop (see below).
        do_get(url, 0, max_bytes)
      rescue
        e -> {:error, "Request error: #{Exception.message(e)}"}
      end
    end

    @max_redirects 5

    defp do_get(_url, depth, _max_bytes) when depth > @max_redirects do
      {:error, "Too many redirects"}
    end

    defp do_get(url, depth, max_bytes) do
      with {:ok, uri, pin_ip} <- Nous.Tools.UrlGuard.validate_pinned(url),
           {:ok, {request_url, connect_opts}} <- pin_connection(url, uri, pin_ip) do
        case Req.get(request_url,
               connect_options: connect_opts,
               receive_timeout: 15_000,
               max_redirects: 0,
               redirect: false,
               into: capped_collector(max_bytes),
               headers: [
                 {"user-agent",
                  "Mozilla/5.0 (compatible; NousBot/1.0; +https://github.com/nyo16/nous)"},
                 {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
               ]
             ) do
          {:ok, %{status: status} = response} when status in 200..299 ->
            with :ok <- check_size(response, max_bytes),
                 :ok <- check_content_type(response.headers) do
              {:ok, response.body}
            end

          {:ok, %{status: status, headers: headers}} when status in 300..399 ->
            location = location_header(headers)

            case location do
              nil ->
                {:error, "HTTP #{status} but no Location header"}

              target ->
                # Recurse with the original hostname URL; do_get re-validates and
                # re-pins the new hop.
                absolute = URI.merge(URI.parse(url), URI.parse(target)) |> URI.to_string()
                do_get(absolute, depth + 1, max_bytes)
            end

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
      end
    end

    # Stream the body instead of letting Req buffer it whole: we get each chunk
    # and abort the transfer the moment the running total crosses the ceiling,
    # so an oversized (or endless) response costs at most `max_bytes` of memory.
    # Req only negotiates compression when `:compressed` is set, which we never
    # set, so these are the same bytes Floki would see — no decompression bomb
    # hides behind the count.
    defp capped_collector(max_bytes) do
      fn {:data, chunk}, {request, response} ->
        body = response.body <> chunk

        if byte_size(body) > max_bytes do
          {:halt, {request, Req.Response.put_private(response, :nous_body_capped, true)}}
        else
          {:cont, {request, %{response | body: body}}}
        end
      end
    end

    defp check_size(response, max_bytes) do
      if Req.Response.get_private(response, :nous_body_capped, false) do
        {:error, "Response exceeded the #{max_bytes} byte limit"}
      else
        :ok
      end
    end

    # Fail CLOSED when the header is absent: without it we cannot tell markup
    # from a binary blob, and guessing is how a tarball ends up in Floki.
    defp check_content_type(headers) do
      case content_type(headers) do
        nil ->
          {:error, "Response has no content-type header; refusing to parse it as HTML"}

        type when type in @allowed_content_types ->
          :ok

        type ->
          {:error, "Unsupported content-type #{inspect(type)} (expected HTML or plain text)"}
      end
    end

    # `text/html; charset=utf-8` — the parameters are none of our business.
    defp content_type(headers) do
      case header(headers, "content-type") do
        nil ->
          nil

        value ->
          value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
      end
    end

    # Pin the connection to the IP UrlGuard validated, closing the DNS-rebinding
    # window (guard resolves one IP, Req would otherwise re-resolve another).
    # We connect to the IP literal but pass the original hostname to Mint for the
    # Host header, SNI, and TLS certificate verification (Req `:hostname` opt).
    #
    # A nil pin means host validation was skipped (only possible via
    # `allow_private_hosts: true`, which web_fetch never sets). Fail CLOSED
    # rather than fetching with the raw hostname + no pin — an unpinned fetch
    # would silently reopen the DNS-rebinding window if that flag is ever
    # wired through here. Thread an explicit opt instead if private-host
    # fetching is genuinely wanted.
    defp pin_connection(_url, _uri, nil),
      do: {:error, "refusing to fetch without a pinned IP (host validation was skipped)"}

    defp pin_connection(_url, %URI{} = uri, ip) do
      ip_str = ip |> :inet.ntoa() |> to_string()
      host_for_url = if tuple_size(ip) == 8, do: "[#{ip_str}]", else: ip_str
      authority = if uri.port, do: "#{host_for_url}:#{uri.port}", else: host_for_url
      path = uri.path || "/"
      query = if uri.query, do: "?#{uri.query}", else: ""
      pinned = "#{uri.scheme}://#{authority}#{path}#{query}"
      {:ok, {pinned, [timeout: 10_000, hostname: uri.host]}}
    end

    defp location_header(headers), do: header(headers, "location")

    # Req returns headers as a string-keyed map of String -> [String]. Names are
    # matched case-insensitively; HTTP does not promise a casing.
    defp header(headers, name) when is_map(headers) do
      case Enum.find(headers, fn {key, _value} -> String.downcase(key) == name end) do
        {_key, [value | _]} -> value
        {_key, value} when is_binary(value) -> value
        _ -> nil
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

    defp extract_title(doc) when is_list(doc) do
      case Floki.find(doc, "title") do
        [{_, _, children} | _] -> Floki.text([{"span", [], children}]) |> String.trim()
        _ -> nil
      end
    end

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
    def do_fetch(_url, _selector \\ nil, _opts \\ []) do
      {:error, "Floki is required. Add {:floki, \"~> 0.36\"} to your deps."}
    end
  end
end
