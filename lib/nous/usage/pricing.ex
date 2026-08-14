defmodule Nous.Usage.Pricing do
  @moduledoc """
  Per-model token prices for turning a `%Nous.Usage{}` into a dollar figure.

  Prices are quoted **per 1M tokens in USD**, the way every vendor publishes
  them. Each entry carries an `:input` and `:output` rate plus optional
  `:cache_read` (a cache hit) and `:cache_write` (creating a cache entry)
  rates, because cached input is billed at a different rate than fresh input —
  which is the whole reason `%Nous.Usage{}` tracks `cache_read_input_tokens`
  and `cache_creation_input_tokens` separately.

  ## Lookup

  `lookup/2` is keyed by `{provider, model}` where `provider` is one of
  `t:Nous.Model.provider/0` and `model` is the API model id string.

  Resolution order:

    1. **Exact match** on `{provider, model}`.
    2. **Longest-prefix match** — model ids carry dated or variant suffixes
       (`"gpt-4o-2026-05-13"`, `"claude-opus-4-5-20251101"`), so the entry
       whose model string is the longest prefix of the requested id wins. The
       prefix must end on a `-` boundary. Longest wins is what keeps
       `"gemini-2.5-flash-lite-preview-09-2025"` on the Flash-Lite price
       instead of falling into the pricier `"gemini-2.5-flash"` entry.

       The trade-off: an unlisted *sibling* variant inherits its family's
       price rather than reporting `:unknown` (ask for `"o1-mini"` and you get
       the `"o1"` rate). Add the sibling through the override config below
       when that matters.
    3. **Local providers** (`:ollama`, `:lmstudio`, `:llamacpp`, `:vllm`,
       `:sglang`) resolve to all-zero rates: you run the weights on your own
       hardware, so there is no per-token invoice. Zero is the honest answer
       here, not `:unknown`.
    4. Otherwise `:unknown`. A wrong price is worse than no price, so an
       unrecognised model never gets a guessed rate and never raises.

  ## Operator overrides

  Fine-tuned, self-hosted, brokered and enterprise-contract models cannot be
  priced from a public table. Supply your own rates, which are merged over the
  built-in table (so they also win on exact keys):

      config :nous, :model_prices, %{
        {:openai, "ft:gpt-4.1-2026-01-01:acme:support:abc123"} =>
          %{input: 3.0, output: 12.0, cache_read: 0.75},
        {:groq, "llama-3.3-70b-versatile"} => %{input: 0.59, output: 0.79}
      }

  Omitted optional keys default conservatively: a missing `:cache_read` bills
  cache hits at the full `:input` rate (no published discount to apply), and a
  missing `:cache_write` bills cache creation at zero (no published surcharge,
  which is how OpenAI prompt caching works).

  ## Price snapshot

  **Prices below were recorded on 2026-08-14** from the vendors' official
  pricing pages:

    * <https://developers.openai.com/api/docs/pricing>
    * <https://platform.claude.com/docs/en/about-claude/pricing>
    * <https://ai.google.dev/gemini-api/docs/pricing>

  This is a snapshot and it **will go stale** — vendors reprice, and this
  table is only refreshed when someone remembers to. Treat the numbers as an
  estimate, and when they are wrong for you, correct them with
  `config :nous, :model_prices` (above) rather than waiting for a release.

  Only models whose published rates were confirmed at that date are listed.
  Deliberate omissions:

    * **Audio, image, realtime and embedding models** — those are billed per
      modality (and sometimes per character or per second), which
      `%Nous.Usage{}` cannot distinguish from text tokens.
    * **`:vertex_ai`** — Gemini on Vertex is invoiced by Google Cloud on its
      own rate card, which is not the Developer API rate card.
    * **`:groq`, `:openrouter`, `:together`, `:mistral`, `:custom`** — broker
      and per-account pricing that varies by model and contract.

  Anything not listed resolves to `:unknown`, which is the honest answer.
  """

  alias Nous.Model

  require Logger

  @typedoc """
  A resolved price, per 1M tokens in USD. All four rates are always present.
  """
  @type price :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float()
        }

  @typedoc "A price table entry as written in the table or in operator config."
  @type entry :: %{
          required(:input) => number(),
          required(:output) => number(),
          optional(:cache_read) => number(),
          optional(:cache_write) => number()
        }

  # Weights you host yourself: electricity is not a per-token invoice.
  @local_providers [:ollama, :lmstudio, :llamacpp, :vllm, :sglang]

  @free_price %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}

  # Prices per 1M tokens in USD, recorded 2026-08-14. See the moduledoc for
  # sources, the staleness warning, and the override config.
  #
  # OpenAI: standard service tier, short-context column. OpenAI does not charge
  # for creating a cache entry ("creating a cache entry has no additional
  # fee"), so `cache_write` is left unset (zero) except on the gpt-5.6
  # generation, which publishes an explicit cache-write rate. Entries with no
  # `cache_read` are models with no published cached-input rate.
  @openai_prices %{
    "gpt-5.6-sol" => %{input: 5.0, output: 30.0, cache_read: 0.5, cache_write: 6.25},
    "gpt-5.6-terra" => %{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 2.5},
    "gpt-5.6-luna" => %{input: 0.2, output: 1.2, cache_read: 0.02, cache_write: 0.25},
    "gpt-5.5" => %{input: 5.0, output: 30.0, cache_read: 0.5},
    "gpt-5.5-pro" => %{input: 30.0, output: 180.0},
    "gpt-5.4" => %{input: 2.5, output: 15.0, cache_read: 0.25},
    "gpt-5.4-mini" => %{input: 0.75, output: 4.5, cache_read: 0.075},
    "gpt-5.4-nano" => %{input: 0.2, output: 1.25, cache_read: 0.02},
    "gpt-5.4-pro" => %{input: 30.0, output: 180.0},
    "gpt-5.2" => %{input: 1.75, output: 14.0, cache_read: 0.175},
    "gpt-5.2-pro" => %{input: 21.0, output: 168.0},
    "gpt-5.1" => %{input: 1.25, output: 10.0, cache_read: 0.125},
    "gpt-5" => %{input: 1.25, output: 10.0, cache_read: 0.125},
    "gpt-5-mini" => %{input: 0.25, output: 2.0, cache_read: 0.025},
    "gpt-5-nano" => %{input: 0.05, output: 0.4, cache_read: 0.005},
    "gpt-5-pro" => %{input: 15.0, output: 120.0},
    "gpt-4.1" => %{input: 2.0, output: 8.0, cache_read: 0.5},
    "gpt-4.1-mini" => %{input: 0.4, output: 1.6, cache_read: 0.1},
    "gpt-4.1-nano" => %{input: 0.1, output: 0.4, cache_read: 0.025},
    "gpt-4o" => %{input: 2.5, output: 10.0, cache_read: 1.25},
    "gpt-4o-2024-05-13" => %{input: 5.0, output: 15.0},
    "gpt-4o-mini" => %{input: 0.15, output: 0.6, cache_read: 0.075},
    "o1" => %{input: 15.0, output: 60.0, cache_read: 7.5},
    "o1-pro" => %{input: 150.0, output: 600.0},
    "o3" => %{input: 2.0, output: 8.0, cache_read: 0.5},
    "o3-pro" => %{input: 20.0, output: 80.0},
    "o3-mini" => %{input: 1.1, output: 4.4, cache_read: 0.55},
    "o4-mini" => %{input: 1.1, output: 4.4, cache_read: 0.275},
    "gpt-4-turbo" => %{input: 10.0, output: 30.0},
    "gpt-3.5-turbo" => %{input: 0.5, output: 1.5},
    "gpt-3.5-turbo-1106" => %{input: 1.0, output: 2.0},
    "gpt-3.5-turbo-instruct" => %{input: 1.5, output: 2.0}
  }

  # Anthropic: `cache_write` is the 5-minute write rate (1.25x input).
  # `%Usage{}` carries a single `cache_creation_input_tokens` counter with no
  # TTL, so 1-hour cache writes (2x input) are under-counted here.
  @anthropic_prices %{
    "claude-fable-5" => %{input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5},
    "claude-mythos-5" => %{input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5},
    "claude-opus-5" => %{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
    "claude-opus-4-8" => %{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
    "claude-opus-4-7" => %{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
    "claude-opus-4-6" => %{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
    "claude-opus-4-5" => %{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
    "claude-opus-4-1" => %{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
    "claude-opus-4" => %{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
    "claude-sonnet-5" => %{input: 2.0, output: 10.0, cache_read: 0.2, cache_write: 2.5},
    "claude-sonnet-4-6" => %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
    "claude-sonnet-4-5" => %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
    "claude-sonnet-4" => %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
    "claude-haiku-4-5" => %{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
    "claude-3-5-haiku" => %{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0}
  }

  # Gemini Developer API, standard tier, text rates, <= 200k prompt tier.
  # `cache_read` is the published "context caching price". Gemini also bills
  # cache *storage* per token-hour, a function of wall-clock time rather than
  # of tokens, so it cannot be derived from `%Usage{}` and `cache_write` stays
  # zero. The 3.6/3.7 Flash rates are promotional rates published through
  # 2026-12-31 that double on 2027-01-01.
  @gemini_prices %{
    "gemini-3.7-flash" => %{input: 0.75, output: 3.75, cache_read: 0.075, cache_write: 0.0},
    "gemini-3.6-flash" => %{input: 0.75, output: 3.75, cache_read: 0.075, cache_write: 0.0},
    "gemini-3.5-flash" => %{input: 1.5, output: 9.0, cache_read: 0.15, cache_write: 0.0},
    "gemini-3.5-flash-lite" => %{input: 0.3, output: 2.5, cache_read: 0.03, cache_write: 0.0},
    "gemini-3.1-pro-preview" => %{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
    "gemini-2.5-pro" => %{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
    "gemini-2.5-flash" => %{input: 0.3, output: 2.5, cache_read: 0.03, cache_write: 0.0},
    "gemini-2.5-flash-lite" => %{input: 0.1, output: 0.4, cache_read: 0.01, cache_write: 0.0}
  }

  @table for {provider, prices} <- [
               openai: @openai_prices,
               anthropic: @anthropic_prices,
               gemini: @gemini_prices
             ],
             {model, entry} <- prices,
             into: %{},
             do: {{provider, model}, entry}

  @doc """
  The effective price table: the built-in snapshot with
  `config :nous, :model_prices` merged over it.

  Entries are returned as written (optional cache rates may be absent);
  `lookup/2` is what fills in the defaults.
  """
  @spec table() :: %{{Model.provider(), String.t()} => entry()}
  def table do
    Map.merge(@table, Application.get_env(:nous, :model_prices, %{}))
  end

  @doc """
  Look up the price for `provider` and `model`.

  Returns a `t:price/0` with all four rates filled in, or `:unknown` when no
  entry matches. See the moduledoc for the exact resolution order (exact
  match, then longest prefix, then zero for local providers).

  ## Examples

      iex> price = Pricing.lookup(:ollama, "llama3.3:70b")
      iex> {price.input, price.output}
      {0.0, 0.0}

      iex> Pricing.lookup(:openai, "no-such-model")
      :unknown

  """
  @spec lookup(Model.provider(), String.t()) :: price() | :unknown
  def lookup(provider, model) when is_atom(provider) and is_binary(model) do
    case find(table(), provider, model) do
      :unknown -> if provider in @local_providers, do: @free_price, else: :unknown
      price -> price
    end
  end

  defp find(table, provider, model) do
    case Map.fetch(table, {provider, model}) do
      {:ok, entry} -> normalize(entry, provider, model)
      :error -> longest_prefix(table, provider, model)
    end
  end

  defp longest_prefix(table, provider, model) do
    table
    |> Enum.filter(fn {{entry_provider, entry_model}, _entry} ->
      entry_provider == provider and family_prefix?(model, entry_model)
    end)
    |> Enum.max_by(
      fn {{_provider, entry_model}, _entry} -> byte_size(entry_model) end,
      fn -> nil end
    )
    |> case do
      nil -> :unknown
      {_key, entry} -> normalize(entry, provider, model)
    end
  end

  # A family prefix must end on a `-` boundary in the requested id, so
  # `"gpt-4o"` claims `"gpt-4o-2026-05-13"` but `"gpt-5"` does not claim
  # `"gpt-5.3-whatever"` — an unreleased generation stays `:unknown` instead of
  # inheriting a stale rate.
  defp family_prefix?(model, entry_model) do
    prefix_size = byte_size(entry_model)

    byte_size(model) > prefix_size and String.starts_with?(model, entry_model) and
      binary_part(model, prefix_size, 1) == "-"
  end

  # Integer rates in operator config are coerced to floats so downstream
  # arithmetic never mixes numeric types.
  defp normalize(%{input: input, output: output} = entry, _provider, _model)
       when is_number(input) and is_number(output) do
    %{
      input: input * 1.0,
      output: output * 1.0,
      cache_read: Map.get(entry, :cache_read, input) * 1.0,
      cache_write: Map.get(entry, :cache_write, 0.0) * 1.0
    }
  end

  defp normalize(entry, provider, model) do
    Logger.warning(
      "Ignoring malformed :model_prices entry for #{inspect({provider, model})}: " <>
        "#{inspect(entry)}. Expected %{input: number, output: number}."
    )

    :unknown
  end
end
