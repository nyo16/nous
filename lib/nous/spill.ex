defmodule Nous.Spill.Locator do
  @moduledoc """
  An opaque handle to spilled content.

  Callers MUST NOT interpret `:id`. It is the backend's own addressing scheme —
  a filesystem path today, an S3 key or a row id tomorrow — and the only
  supported ways to use it are `Nous.Spill.fetch/1` and
  `c:Nous.Spill.retrieval_hint/1`. Rendering a locator into a prompt as though a
  `file_read` tool could open it is exactly the assumption this struct exists to
  prevent.
  """

  alias __MODULE__

  @type t :: %Locator{
          store: module(),
          id: String.t(),
          bytes: non_neg_integer(),
          name: String.t()
        }

  @enforce_keys [:store, :id, :bytes, :name]
  defstruct [:store, :id, :bytes, :name]
end

defmodule Nous.Spill do
  @moduledoc """
  Content-addressed overflow for oversized tool results.

  A 4 MB `grep` result costs roughly a million tokens of context and is almost
  never read in full. Spilling writes it somewhere durable, hands the model a
  short preview plus a locator, and lets it fetch the rest only if it actually
  needs to.

  ## Shape

      {:ok, locator} = Nous.Spill.save_text(config, %{
        owner: "session-abc",
        source: "file_grep",
        suggested_name: "grep-results.txt",
        content: big_text
      })

      Nous.Spill.retrieval_hint(locator)
      #=> "Read it with the file_read tool at /var/…/session-…/a1b2-grep-results.txt"

      {:ok, ^big_text} = Nous.Spill.fetch(locator)

  ## Configuration

  Per run, in `deps` — the convention every other pluggable backend in Nous
  follows (`:memory_config`, `:summarization_config`):

      Nous.run(agent, prompt,
        deps: %{
          spill_config: %{
            store: Nous.Spill.Local,
            opts: [root: "/var/lib/nous/spill"],
            max_inline_bytes: 65_536
          }
        }
      )

  Or application-wide, for a deployment that wants it everywhere:

      config :nous, :spill, %{store: Nous.Spill.Local, opts: [root: "/var/lib/nous/spill"]}

  `deps[:spill_config]` wins over application config. With neither, spilling is
  **disabled** and results are left inline exactly as before — this is opt-in.

  ## Retention

  Spilled files **persist until the operator deletes them**. There is no reaper,
  by design: a background process deleting content the model may still hold a
  locator for is a correctness problem disguised as housekeeping, and the right
  retention policy depends on the deployment (a per-session tmpdir wiped on exit,
  a nightly cron, an S3 lifecycle rule). Point `:root` at a directory you are
  willing to manage.
  """

  alias Nous.Spill.Locator

  require Logger

  @typedoc """
  What to spill. `owner` scopes the content (a session id); `source` names the
  producer (a tool name) for debuggability; `suggested_name` is advisory — the
  backend sanitises it.
  """
  @type attrs :: %{
          required(:owner) => String.t(),
          required(:source) => String.t(),
          required(:suggested_name) => String.t(),
          required(:content) => binary()
        }

  @typedoc """
  Resolved configuration: the backend, its options, and the inline byte ceiling.
  """
  @type config :: %{store: module(), opts: keyword(), max_inline_bytes: pos_integer()}

  @doc """
  Persist `content` and return an opaque locator.
  """
  @callback save_text(attrs()) :: {:ok, Locator.t()} | {:error, term()}

  @doc """
  Read spilled content back. MUST round-trip `save_text/1`'s bytes exactly.
  """
  @callback fetch(Locator.t()) :: {:ok, binary()} | {:error, term()}

  @doc """
  A sentence telling the model how to retrieve this locator with the tools it
  actually has. The backend owns this string because only the backend knows
  whether its ids are readable paths, URLs, or opaque keys.
  """
  @callback retrieval_hint(Locator.t()) :: String.t()

  @default_max_inline_bytes 65_536

  # Preview split: the head is where the answer usually is, the tail catches
  # error summaries and totals. Same 4:1 ratio the pruner uses.
  @head_share 4

  @doc """
  Resolve the effective spill configuration, or `:disabled`.

  `ctx` may be a `Nous.RunContext`, a `Nous.Agent.Context`, a bare deps map, or
  `nil`. Precedence: `deps[:spill_config]`, then `config :nous, :spill`, then
  disabled.
  """
  @spec config(map() | nil) :: {:ok, config()} | :disabled
  def config(ctx) do
    raw = deps_config(ctx) || Application.get_env(:nous, :spill)

    case raw do
      %{store: store} = cfg when is_atom(store) and not is_nil(store) ->
        {:ok,
         %{
           store: store,
           opts: Map.get(cfg, :opts, []),
           max_inline_bytes: Map.get(cfg, :max_inline_bytes, @default_max_inline_bytes)
         }}

      _none ->
        :disabled
    end
  end

  @doc """
  Persist `content` through the configured backend.
  """
  @spec save_text(config(), attrs()) :: {:ok, Locator.t()} | {:error, term()}
  def save_text(%{store: store, opts: opts}, attrs) do
    store.save_text(Map.put(attrs, :opts, opts))
  end

  @doc """
  Read spilled content back through the backend that wrote it.
  """
  @spec fetch(Locator.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(%Locator{store: store} = locator), do: store.fetch(locator)

  @doc """
  The backend's retrieval sentence for this locator.
  """
  @spec retrieval_hint(Locator.t()) :: String.t()
  def retrieval_hint(%Locator{store: store} = locator), do: store.retrieval_hint(locator)

  @doc """
  Spill `text` if it exceeds the inline ceiling, returning the replacement.

  Returns `{:spilled, replacement_text, locator}` when the content was written,
  or `:inline` when it was small enough, spilling is disabled, or the backend
  failed.

  Three rules are load-bearing:

    * **Best effort.** A backend error logs and returns `:inline`. Spilling is an
      optimisation; it must never turn a successful tool call into a failure.
    * **The notice pays for itself.** The replacement — preview *plus* the notice
      describing the spill *plus* the newlines joining them — is never larger
      than `max_inline_bytes`. The notice is measured against an upper bound of
      the omitted-byte count before any preview budget is handed out, so the cap
      cannot be exceeded by the accounting itself. The one exception is inherent:
      if the notice *alone* is larger than the cap (a tiny `max_inline_bytes`
      against a long locator id), the notice wins and the preview is empty — a
      replacement the model cannot act on would defeat the point of spilling.
    * **Text only.** Content that is not valid UTF-8 is left inline: a byte-slice
      preview of binary content is noise, and the store's contract is text.
  """
  @spec maybe_spill(String.t(), keyword()) ::
          {:spilled, String.t(), Locator.t()} | :inline
  def maybe_spill(text, opts) when is_binary(text) do
    ctx = Keyword.get(opts, :ctx)

    with {:ok, cfg} <- config(ctx),
         true <- byte_size(text) > cfg.max_inline_bytes,
         true <- String.valid?(text) do
      spill(text, cfg, opts)
    else
      _no -> :inline
    end
  end

  # ---------------------------------------------------------------------------

  defp spill(text, cfg, opts) do
    attrs = %{
      owner: Keyword.get(opts, :owner) || "unscoped",
      source: Keyword.get(opts, :source) || "unknown",
      suggested_name: Keyword.get(opts, :suggested_name) || "result.txt",
      content: text
    }

    case save_text(cfg, attrs) do
      {:ok, locator} ->
        {:spilled, replacement(text, locator, cfg.max_inline_bytes), locator}

      {:error, reason} ->
        Logger.warning(
          "Nous.Spill: #{inspect(cfg.store)} failed to store #{byte_size(text)} bytes " <>
            "from #{attrs.source} (#{inspect(reason)}); keeping the result inline."
        )

        :inline
    end
  end

  # Reserve the notice's own bytes BEFORE budgeting the preview. The notice
  # quotes the omitted-byte count, which depends on how much preview we keep —
  # circular. Broken by measuring the notice against the whole input: the real
  # omitted count is always smaller, and a smaller integer never renders longer,
  # so the reservation is an upper bound.
  #
  # `+ @separator_bytes` reserves the two newlines that join preview to notice.
  # Forgetting them put the replacement 2 bytes over the cap whenever the preview
  # budget was fully consumed, which is precisely the case the cap exists for.
  @separator_bytes 2

  defp replacement(text, locator, max_bytes) do
    reserved = byte_size(notice(byte_size(text), locator)) + @separator_bytes
    preview_budget = max(max_bytes - reserved, 0)

    head_budget = div(preview_budget * @head_share, @head_share + 1)
    tail_budget = preview_budget - head_budget

    head = utf8_prefix(text, head_budget)
    tail = utf8_suffix(text, tail_budget)

    omitted = byte_size(text) - byte_size(head) - byte_size(tail)

    join(head, notice(omitted, locator), tail)
  end

  # Only emit a separator where there is something on both sides of it, so the
  # degenerate small-cap case spends nothing on formatting.
  defp join("", notice, ""), do: notice
  defp join(head, notice, ""), do: head <> "\n" <> notice
  defp join("", notice, tail), do: notice <> "\n" <> tail
  defp join(head, notice, tail), do: head <> "\n" <> notice <> "\n" <> tail

  defp notice(omitted, locator) do
    "(Omitted #{omitted} bytes. Full result stored at: #{locator.id}. " <>
      "#{retrieval_hint(locator)})"
  end

  # Byte-bounded, codepoint-safe: take at most `bytes`, then walk back off any
  # partial UTF-8 sequence the cut landed inside. `String.slice/2` counts
  # graphemes, which cannot honour a byte budget.
  defp utf8_prefix(_text, 0), do: ""

  defp utf8_prefix(text, bytes) when byte_size(text) <= bytes, do: text

  defp utf8_prefix(text, bytes) do
    candidate = binary_part(text, 0, bytes)

    if String.valid?(candidate), do: candidate, else: utf8_prefix(text, bytes - 1)
  end

  defp utf8_suffix(_text, 0), do: ""

  defp utf8_suffix(text, bytes) when byte_size(text) <= bytes, do: text

  defp utf8_suffix(text, bytes) do
    size = byte_size(text)
    candidate = binary_part(text, size - bytes, bytes)

    if String.valid?(candidate), do: candidate, else: utf8_suffix(text, bytes - 1)
  end

  defp deps_config(%{deps: deps}) when is_map(deps), do: Map.get(deps, :spill_config)
  defp deps_config(%{} = deps), do: Map.get(deps, :spill_config)
  defp deps_config(_other), do: nil
end
