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

    Concurrency is bounded too: every request holds one of a fixed set of 64
    pinned connection pools for its duration, and a fetch that finds every slot
    taken fails rather than queueing.
    """

    require Logger

    # Ceiling on the response body we are willing to buffer, in bytes. The URL
    # is model-controlled, so an uncapped fetch of a multi-gigabyte file (or of
    # an endpoint that never stops sending) would take the node down with it.
    @default_max_bytes 5_000_000

    # The extractor only understands markup. Anything else (PDF, image,
    # tarball, JSON) is rejected before it reaches Floki. Compared against the
    # bare media type, with any `; charset=...` parameters stripped.
    @allowed_content_types ~w(text/html application/xhtml+xml text/plain)

    # Socket connect timeout for the pinned connection, in ms.
    @connect_timeout 10_000

    # Ceiling on the number of pinned Finch instances that may be live at once.
    # Every hop of every fetch holds exactly one for the duration of a single
    # request, so this is also the node-wide concurrency ceiling for web_fetch.
    # Sized above `search_scrape`'s max_concurrency clamp (20) so a single
    # maximally-parallel scrape cannot exhaust it.
    @max_pinned_pools 64

    # Naming a Finch instance requires an atom and the hostname is
    # model-controlled, so the names are minted here at compile time. Deriving
    # them from the hostname at runtime — which is what Req's `:connect_options`
    # path does internally (`Req.Finch.pool_name/1` calls `Module.concat/2` on a
    # hash of the pool options) — leaks one permanent atom AND one permanent
    # Finch supervision tree per distinct hostname the model asks for.
    @pinned_pool_slots for i <- 0..(@max_pinned_pools - 1),
                           do: Module.concat([__MODULE__, Finch, "Slot#{i}"])

    @typedoc """
    A fetched page. `:title` is nil when the document carries no `<title>`.
    """
    @type page :: %{
            url: String.t(),
            title: String.t() | nil,
            content: String.t(),
            word_count: non_neg_integer(),
            fetched_at: String.t()
          }

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
    @spec fetch_page(Nous.RunContext.t(), map()) ::
            %{
              url: String.t(),
              title: String.t() | nil,
              content: String.t(),
              word_count: non_neg_integer(),
              fetched_at: String.t(),
              success: true
            }
            | %{success: false, error: String.t()}
            | %{success: false, error: String.t(), url: term()}
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
    @spec do_fetch(String.t(), String.t() | nil, keyword()) ::
            {:ok, page()} | {:error, String.t()}
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
           {:ok, {request_url, hostname}} <- pin_connection(uri, pin_ip),
           {:ok, response} <- pinned_get(request_url, hostname, max_bytes) do
        handle_response(url, response, depth, max_bytes)
      end
    end

    defp handle_response(_url, %{status: status} = response, _depth, max_bytes)
         when status in 200..299 do
      with :ok <- check_size(response, max_bytes),
           :ok <- check_content_type(response.headers) do
        {:ok, response.body}
      end
    end

    defp handle_response(url, %{status: status, headers: headers}, depth, max_bytes)
         when status in 300..399 do
      case location_header(headers) do
        nil ->
          {:error, "HTTP #{status} but no Location header"}

        target ->
          # Recurse with the original hostname URL; do_get re-validates and
          # re-pins the new hop.
          absolute = URI.merge(URI.parse(url), URI.parse(target)) |> URI.to_string()
          do_get(absolute, depth + 1, max_bytes)
      end
    end

    defp handle_response(_url, %{status: status}, _depth, _max_bytes),
      do: {:error, "HTTP #{status}"}

    # One request against a Finch instance dedicated to this hop's pin, released
    # the moment the request is done — including before a redirect recurses, so
    # a 5-hop chain still only ever holds one slot.
    #
    # The alternative, Req's `:connect_options`, silently starts a Finch
    # supervision tree under `Req.FinchSupervisor` keyed by a hash of those
    # options and never stops it. Since the options carry the hostname and the
    # hostname comes from the model, that is an unbounded leak of both
    # supervision trees and atoms. `finch: [name: ...]` is the escape hatch:
    # Req uses the instance we hand it and starts nothing of its own.
    #
    # retry: false — Req defaults to `:safe_transient`, which retries a GET up
    # to 3 more times on 408/429/5xx and transport errors. On a model-supplied
    # URL that quadruples egress and the `max_bytes` transfer, and it re-runs
    # the connection (a fresh pool, hence a fresh DNS resolution of the pinned
    # hostname) outside the guard that validated this hop — single-fetch
    # reasoning about SSRF requires exactly one request per validated pin.
    defp pinned_get(request_url, hostname, max_bytes) do
      case claim_pinned_pool(@pinned_pool_slots, hostname) do
        {:ok, finch, pool} ->
          try do
            case Req.get(request_url,
                   finch: [name: finch],
                   receive_timeout: 15_000,
                   max_redirects: 0,
                   redirect: false,
                   retry: false,
                   into: capped_collector(max_bytes),
                   headers: [
                     {"user-agent",
                      "Mozilla/5.0 (compatible; NousBot/1.0; +https://github.com/nyo16/nous)"},
                     {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
                   ]
                 ) do
              {:ok, response} -> {:ok, response}
              {:error, reason} -> {:error, "Request failed: #{inspect(reason)}"}
            end
          after
            Supervisor.stop(pool, :normal)
          end

        :error ->
          {:error, "Too many concurrent web fetches (#{@max_pinned_pools} in flight)"}

        {:error, _reason} = error ->
          error
      end
    end

    # Finch's own name registration is the mutex: whoever starts the slot owns
    # it until it is stopped. `size: 1` because a slot serves exactly one
    # request, and the instance is linked to the caller so a crashing fetch
    # cannot strand it.
    defp claim_pinned_pool([], _hostname), do: :error

    defp claim_pinned_pool([name | rest], hostname) do
      pools = %{
        default: [
          size: 1,
          count: 1,
          protocols: [:http1],
          conn_opts: [hostname: hostname, transport_opts: [timeout: @connect_timeout]]
        ]
      }

      case Finch.start_link(name: name, pools: pools) do
        {:ok, pool} -> {:ok, name, pool}
        {:error, {:already_started, _pid}} -> claim_pinned_pool(rest, hostname)
        other -> pool_start_failed(name, other)
      end
    end

    # `Finch.start_link/1` is `Supervisor.start_link/3` underneath, so its
    # failure set is open: besides `{:already_started, _}` it can answer
    # `{:error, {:shutdown, {:failed_to_start_child, ...}}}` (one of Finch's
    # own registries or its pool manager refused to start) or `:ignore`. Those
    # used to fall off the `case` as a `CaseClauseError`, which `fetch_url/2`'s
    # rescue laundered into a generic failure with the real reason discarded.
    #
    # We do NOT walk to the next slot: a start failure that is not contention
    # will repeat on all 64 of them and then answer "too many concurrent web
    # fetches", which would be false. Report the real reason instead, and log
    # it because the model only ever sees the sentence, not the term.
    defp pool_start_failed(name, result) do
      Logger.warning(
        "WebFetch: pinned connection pool #{inspect(name)} failed to start: #{inspect(result)}"
      )

      {:error, "Could not start a pinned connection pool: #{inspect(result)}"}
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
    #
    # Public (but `@doc false`, like `do_fetch/3`) purely so the fail-closed
    # clause is testable: nothing in `do_get/3` can reach it today, which is
    # exactly how it stayed untested through two audits.
    @doc false
    @spec pin_connection(URI.t(), :inet.ip_address() | nil) ::
            {:ok, {String.t(), String.t()}} | {:error, String.t()}
    def pin_connection(uri, ip)

    def pin_connection(_uri, nil),
      do: {:error, "refusing to fetch without a pinned IP (host validation was skipped)"}

    def pin_connection(%URI{} = uri, ip) do
      ip_str = ip |> :inet.ntoa() |> to_string()
      host_for_url = if tuple_size(ip) == 8, do: "[#{ip_str}]", else: ip_str
      authority = if uri.port, do: "#{host_for_url}:#{uri.port}", else: host_for_url
      path = uri.path || "/"
      query = if uri.query, do: "?#{uri.query}", else: ""
      pinned = "#{uri.scheme}://#{authority}#{path}#{query}"
      {:ok, {pinned, uri.host}}
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

    @spec fetch_page(Nous.RunContext.t(), map()) :: %{success: false, error: String.t()}
    def fetch_page(_ctx, _args) do
      %{success: false, error: "Floki is required. Add {:floki, \"~> 0.36\"} to your deps."}
    end

    @doc false
    @spec do_fetch(String.t(), String.t() | nil, keyword()) :: {:error, String.t()}
    def do_fetch(_url, _selector \\ nil, _opts \\ []) do
      {:error, "Floki is required. Add {:floki, \"~> 0.36\"} to your deps."}
    end
  end
end
