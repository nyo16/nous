defmodule Nous.Eval.Optimizer.Lint do
  @moduledoc """
  Cheap, deterministic checks on a reflector's proposed text, run before a
  proposal is evaluated (and spends budget):

    * **Held-out leakage.** A proposal that repeats a run of
      8 consecutive words from a validation or test case (its input or
      any string in its `expected`) is rejected: text memorised from the
      data the candidate is judged on inflates exactly the numbers that
      decide acceptance. Words are compared case-folded with punctuation
      stripped.
    * **Fence markers.** A proposal containing `<<<`, `>>>` or a fence
      boundary (`INPUT_` followed by a 16-character token) is rejected: it
      would carry a fence escape from untrusted trace text into an agent's
      system prompt.

  The reflector never receives held-out text, so a leak can only come from
  train cases that share it, from the model's own knowledge, or from an
  injected trace; whichever it is, the proposal is not used.
  """

  @window 8
  @boundary ~r/INPUT_[A-Za-z0-9_-]{16}/

  @doc """
  The held-out word windows to check proposals against, from the cases of
  the validation and test splits.
  """
  @spec heldout_windows([Nous.Eval.Case.t()]) :: MapSet.t()
  def heldout_windows(cases) do
    cases
    |> Enum.flat_map(&case_texts/1)
    |> Enum.flat_map(&windows/1)
    |> MapSet.new()
  end

  @doc """
  Checks `updates` (component key => proposed text).

  Returns `:ok`, `{:error, {:heldout_leak, key}}` or
  `{:error, {:fence_marker, key}}`.
  """
  @spec check(%{String.t() => String.t()}, MapSet.t()) ::
          :ok | {:error, {:heldout_leak | :fence_marker, String.t()}}
  def check(updates, windows) do
    Enum.reduce_while(Enum.sort(updates), :ok, fn {key, text}, :ok ->
      cond do
        fence_marker?(text) -> {:halt, {:error, {:fence_marker, key}}}
        leaks?(text, windows) -> {:halt, {:error, {:heldout_leak, key}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp fence_marker?(text),
    do: String.contains?(text, ["<<<", ">>>"]) or Regex.match?(@boundary, text)

  defp leaks?(_text, windows) when map_size(windows) == 0, do: false
  defp leaks?(text, windows), do: text |> windows() |> Enum.any?(&MapSet.member?(windows, &1))

  defp case_texts(%Nous.Eval.Case{input: input, expected: expected}),
    do: input_texts(input) ++ strings(expected)

  defp input_texts(text) when is_binary(text), do: [text]

  defp input_texts(messages) when is_list(messages),
    do: Enum.map(messages, &Nous.Message.extract_text/1)

  defp strings(text) when is_binary(text), do: [text]
  defp strings(%{__struct__: _}), do: []
  defp strings(%{} = map), do: Enum.flat_map(map, fn {_key, value} -> strings(value) end)
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(_other), do: []

  defp windows(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
      |> String.split()

    if length(words) < @window,
      do: [],
      else: words |> Enum.chunk_every(@window, 1, :discard) |> Enum.map(&Enum.join(&1, " "))
  end
end
