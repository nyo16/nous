defmodule Nous.Usage.PricingTest do
  # async: false — the override tests mutate application env.
  use ExUnit.Case, async: false

  alias Nous.Usage.Pricing

  doctest Pricing

  setup do
    original = Application.fetch_env(:nous, :model_prices)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:nous, :model_prices, value)
        :error -> Application.delete_env(:nous, :model_prices)
      end
    end)

    :ok
  end

  describe "lookup/2 exact match" do
    test "returns all four rates for a listed model" do
      price = Pricing.lookup(:anthropic, "claude-sonnet-4-5")

      assert %{input: input, output: output, cache_read: cache_read, cache_write: cache_write} =
               price

      # Rates come from the snapshot table; the relations, not the magic
      # numbers, are what a plausible bug would break (swapped input/output,
      # cache rates falling back to the input rate for a provider that
      # publishes them).
      assert input > 0.0
      assert output > input
      assert cache_read < input
      assert cache_write > input
    end

    test "an exact key is preferred over a shorter family prefix" do
      # "gpt-4o-2024-05-13" is its own entry and must not inherit "gpt-4o".
      refute Pricing.lookup(:openai, "gpt-4o-2024-05-13") == Pricing.lookup(:openai, "gpt-4o")
    end
  end

  describe "lookup/2 prefix fallback" do
    test "a dated suffix resolves to the family entry" do
      assert Pricing.lookup(:openai, "gpt-4o-2026-05-13") == Pricing.lookup(:openai, "gpt-4o")
      assert is_map(Pricing.lookup(:openai, "gpt-4o-2026-05-13"))
    end

    test "longest prefix wins over a shorter one that also matches" do
      lite = Pricing.lookup(:gemini, "gemini-2.5-flash-lite")
      flash = Pricing.lookup(:gemini, "gemini-2.5-flash")

      assert is_map(lite)
      refute lite == flash
      assert Pricing.lookup(:gemini, "gemini-2.5-flash-lite-preview-09-2025") == lite
    end

    test "longest prefix wins with hand-picked override rates" do
      Application.put_env(:nous, :model_prices, %{
        {:openai, "acme"} => %{input: 1.0, output: 2.0},
        {:openai, "acme-large"} => %{input: 10.0, output: 20.0}
      })

      assert %{input: 10.0, output: 20.0} = Pricing.lookup(:openai, "acme-large-2026-01-01")
      assert %{input: 1.0, output: 2.0} = Pricing.lookup(:openai, "acme-small-2026-01-01")
    end

    test "a prefix only matches on a dash boundary" do
      # "gpt-5" must not claim a future "gpt-5.3-*" generation: an unlisted
      # generation is unknown, not silently priced at the older rate.
      assert Pricing.lookup(:openai, "gpt-5.3-hypothetical") == :unknown
      assert is_map(Pricing.lookup(:openai, "gpt-5-2026-01-01"))
    end
  end

  describe "lookup/2 unknown models" do
    test "returns :unknown for an unlisted model" do
      assert Pricing.lookup(:openai, "totally-made-up-model") == :unknown
    end

    test "returns :unknown for providers with no published rate card" do
      assert Pricing.lookup(:groq, "llama-3.3-70b-versatile") == :unknown
      assert Pricing.lookup(:vertex_ai, "gemini-2.5-pro") == :unknown
    end
  end

  describe "lookup/2 local providers" do
    test "self-hosted providers are free for any model" do
      for provider <- [:ollama, :lmstudio, :llamacpp, :vllm, :sglang] do
        price = Pricing.lookup(provider, "some-local-weights-#{provider}")

        assert price.input == 0.0
        assert price.output == 0.0
        assert price.cache_read == 0.0
        assert price.cache_write == 0.0
      end
    end
  end

  describe "lookup/2 operator overrides" do
    test "an override beats the built-in table" do
      builtin = Pricing.lookup(:openai, "gpt-4o")

      Application.put_env(:nous, :model_prices, %{
        {:openai, "gpt-4o"} => %{input: 99.0, output: 111.0, cache_read: 9.0, cache_write: 1.0}
      })

      assert %{input: 99.0, output: 111.0, cache_read: 9.0, cache_write: 1.0} =
               Pricing.lookup(:openai, "gpt-4o")

      refute Pricing.lookup(:openai, "gpt-4o") == builtin
    end

    test "an override prices a model the built-in table does not know" do
      assert Pricing.lookup(:openai, "ft:gpt-4.1:acme:abc123") == :unknown

      Application.put_env(:nous, :model_prices, %{
        {:openai, "ft:gpt-4.1:acme:abc123"} => %{input: 3.0, output: 12.0}
      })

      assert %{input: 3.0, output: 12.0} = Pricing.lookup(:openai, "ft:gpt-4.1:acme:abc123")
    end

    test "an override can price a local provider that would otherwise be free" do
      Application.put_env(:nous, :model_prices, %{
        {:ollama, "internal-chargeback"} => %{input: 0.5, output: 1.5}
      })

      assert %{input: 0.5, output: 1.5} = Pricing.lookup(:ollama, "internal-chargeback")
      assert Pricing.lookup(:ollama, "anything-else").input == 0.0
    end

    test "integer rates are coerced to floats" do
      Application.put_env(:nous, :model_prices, %{
        {:openai, "int-rates"} => %{input: 3, output: 6}
      })

      price = Pricing.lookup(:openai, "int-rates")

      assert price.input === 3.0
      assert price.output === 6.0
      assert price.cache_read === 3.0
      assert price.cache_write === 0.0
    end

    test "omitted cache rates default to the input rate and to zero" do
      Application.put_env(:nous, :model_prices, %{
        {:openai, "no-cache-rates"} => %{input: 4.0, output: 8.0}
      })

      price = Pricing.lookup(:openai, "no-cache-rates")

      assert price.cache_read == 4.0
      assert price.cache_write == 0.0
    end

    test "a malformed override is ignored instead of raising" do
      Application.put_env(:nous, :model_prices, %{
        {:openai, "bad-entry"} => %{in: 1.0, out: 2.0}
      })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Pricing.lookup(:openai, "bad-entry") == :unknown
        end)

      assert log =~ "Ignoring malformed :model_prices entry"
    end
  end

  describe "table/0" do
    test "merges overrides over the built-in snapshot" do
      Application.put_env(:nous, :model_prices, %{
        {:openai, "gpt-4o"} => %{input: 1.0, output: 1.0}
      })

      table = Pricing.table()

      assert table[{:openai, "gpt-4o"}] == %{input: 1.0, output: 1.0}
      assert Map.has_key?(table, {:anthropic, "claude-sonnet-4-5"})
    end
  end
end
