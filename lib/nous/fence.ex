defmodule Nous.Fence do
  @moduledoc false
  # The random-boundary fence for untrusted text sent to an LLM.
  #
  # Untrusted text (user input, agent output, tool results) is enclosed between
  # `<<<BOUNDARY` and `BOUNDARY>>>` markers, and the prompt tells the model that
  # everything between the markers is data, never instructions. The boundary is
  # random per call, so the text cannot close the fence early and smuggle
  # instructions after it (an attacker would have to guess 96 random bits), and
  # an attacker cannot embed a verdict line that the model echoes back as its
  # own (second-order injection).
  #
  # Used by `Nous.Plugins.InputGuard.Strategies.LLMJudge` and the eval judge
  # (`Nous.Eval.Scorers.Judge`).

  @prefix "INPUT_"

  # Attempts at minting a boundary that occurs in none of the texts. A random
  # 96-bit boundary only collides with text that already contains it, which a
  # fresh boundary per call rules out; the retry is belt and braces.
  @attempts 3

  @doc false
  # A fresh, unguessable boundary.
  @spec new_boundary() :: String.t()
  def new_boundary,
    do: @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc false
  # A fresh boundary that occurs in none of `texts`, or an error when every
  # attempt collided (the texts are then refused rather than fenced).
  @spec boundary_for([String.t()]) :: {:ok, String.t()} | {:error, :boundary_collision}
  def boundary_for(texts) when is_list(texts), do: boundary_for(texts, @attempts)

  defp boundary_for(_texts, 0), do: {:error, :boundary_collision}

  defp boundary_for(texts, attempts) do
    boundary = new_boundary()

    if Enum.any?(texts, &String.contains?(&1, boundary)),
      do: boundary_for(texts, attempts - 1),
      else: {:ok, boundary}
  end

  @doc false
  # Encloses `text` in the fence. With a `label`, the label is repeated on the
  # opening and closing marker (`<<<BOUNDARY LABEL` ... `BOUNDARY LABEL>>>`), so
  # several fenced spans in one prompt stay distinguishable. Raises
  # `ArgumentError` when `text` contains the boundary: such a fence would not
  # hold.
  @spec wrap(String.t(), String.t(), String.t() | nil) :: String.t()
  def wrap(text, boundary, label \\ nil) when is_binary(text) and is_binary(boundary) do
    if String.contains?(text, boundary) do
      raise ArgumentError, "the fenced text contains the fence boundary"
    end

    marker = if label, do: boundary <> " " <> label, else: boundary
    "<<<" <> marker <> "\n" <> text <> "\n" <> marker <> ">>>"
  end

  @doc false
  # Breaks up fence-like markers (`<<<`, `>>>`) in untrusted text, so text that
  # imitates a fence (a fake opener or closer with a guessed boundary) reads as
  # plain characters. The text stays legible for the model.
  @spec neutralize(String.t()) :: String.t()
  def neutralize(text) when is_binary(text) do
    text
    |> String.replace("<<<", "< < <")
    |> String.replace(">>>", "> > >")
  end
end
