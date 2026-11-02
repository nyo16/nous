defmodule Nous.Eval.Online.Sampler do
  @moduledoc """
  The deterministic sampling decision of `Nous.Eval.Online`.

  A trace is sampled at `rate` when its 56-bit randomness `r` is below
  `trunc(rate * 2^56)`. For a Nous trace id (32 hex characters, 16 random
  bytes) `r` is its rightmost 7 bytes, the randomness the OpenTelemetry
  probability sampler uses; any other key (a session id, a trace id seeded
  by the caller in another format) is hashed with SHA-256 and the first 7
  bytes are used.

  With a salt (`Nous.Eval.Online`'s `:sampling_salt`, applied to session
  keys) `r` is instead the first 7 bytes of `HMAC-SHA-256(salt, key)`, for
  any key. Without one the decision for a key is public: anyone who can
  choose a session id can compute it with `sampled?/2` and keep their
  sessions out of (or in) the sample. A secret salt makes the decision
  unpredictable to them; changing the salt reshuffles which sessions are
  sampled.

  Consequences:

    * the same key (and salt) gets the same decision on every node, after
      every restart and on every replay
    * a lower rate samples a subset of a higher one: `sampled?(key, q)`
      implies `sampled?(key, p)` whenever `q <= p`, so a rule sampling at
      `q` within traces captured at `p` only ever needs captured traces
    * no random number generator is involved

      iex> Nous.Eval.Online.Sampler.sampled?("4bf92f3577b34da6a3ce929d0e0e4736", 1.0)
      true
      iex> Nous.Eval.Online.Sampler.sampled?("4bf92f3577b34da6a3ce929d0e0e4736", 0.0)
      false
  """

  import Bitwise

  alias Nous.Eval.Online.Salt

  @two56 1 <<< 56

  @doc "The sampling threshold for `rate` (`0.0..1.0`): `trunc(rate * 2^56)`."
  @spec threshold(number()) :: non_neg_integer()
  def threshold(rate) when is_number(rate) and rate >= 0 and rate <= 1, do: trunc(rate * @two56)

  @doc """
  The 56-bit randomness of `key` (see the moduledoc), salted when `salt` is
  a binary.
  """
  @spec randomness(String.t(), binary() | nil) :: non_neg_integer()
  def randomness(key, salt \\ nil)

  def randomness(key, salt) when is_binary(key) and is_binary(salt) do
    <<r::unsigned-56, _::binary>> = :crypto.mac(:hmac, :sha256, salt, key)
    r
  end

  def randomness(<<_head::binary-size(18), low::binary-size(14)>> = key, nil) do
    case Base.decode16(low, case: :mixed) do
      {:ok, <<r::unsigned-56>>} -> if hex_head?(key), do: r, else: hashed(key)
      :error -> hashed(key)
    end
  end

  def randomness(key, nil) when is_binary(key), do: hashed(key)

  @doc "Whether `key` is sampled at `rate`, salted when `salt` is a binary."
  @spec sampled?(String.t(), number(), binary() | nil) :: boolean()
  def sampled?(key, rate, salt \\ nil) when is_binary(key),
    do: randomness(key, salt) < threshold(rate)

  @doc false
  # The hot-path form: the threshold is computed once at configuration time.
  # The configured salt arrives opaque (`Nous.Eval.Online.Salt`) and is read
  # only here.
  @spec below?(String.t(), non_neg_integer(), Salt.t() | nil) :: boolean()
  def below?(key, threshold, salt \\ nil)

  def below?(key, threshold, %Salt{secret: secret}) when is_binary(key),
    do: randomness(key, secret.()) < threshold

  def below?(key, threshold, nil) when is_binary(key), do: randomness(key) < threshold

  defp hex_head?(<<head::binary-size(18), _::binary>>),
    do: match?({:ok, _}, Base.decode16(head, case: :mixed))

  defp hashed(key) do
    <<r::unsigned-56, _::binary>> = :crypto.hash(:sha256, key)
    r
  end
end
