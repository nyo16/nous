defmodule Nous.JSON do
  @moduledoc false

  @doc """
  Encode data to pretty-printed JSON string.
  """
  @spec pretty_encode!(term()) :: String.t()
  def pretty_encode!(data) do
    data |> JSON.encode!() |> pretty_print()
  end

  defp pretty_print(json) when is_binary(json) do
    json
    |> String.graphemes()
    |> do_pretty(0, false, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp do_pretty([], _indent, _in_string, acc), do: acc

  defp do_pretty(["\\" | [next | rest]], indent, true, acc),
    do: do_pretty(rest, indent, true, [next, "\\" | acc])

  defp do_pretty(["\"" | rest], indent, in_string, acc),
    do: do_pretty(rest, indent, !in_string, ["\"" | acc])

  defp do_pretty([char | rest], indent, true, acc),
    do: do_pretty(rest, indent, true, [char | acc])

  defp do_pretty(["{" | rest], indent, false, acc),
    do: open_bracket(rest, indent, "{", acc)

  defp do_pretty(["[" | rest], indent, false, acc),
    do: open_bracket(rest, indent, "[", acc)

  defp do_pretty(["}" | rest], indent, false, acc),
    do: close_bracket(rest, indent, "}", acc)

  defp do_pretty(["]" | rest], indent, false, acc),
    do: close_bracket(rest, indent, "]", acc)

  defp do_pretty(["," | rest], indent, false, acc),
    do: do_pretty(rest, indent, false, [pad(indent), "\n", "," | acc])

  defp do_pretty([":" | rest], indent, false, acc),
    do: do_pretty(rest, indent, false, [" ", ":" | acc])

  defp do_pretty([" " | rest], indent, false, acc),
    do: do_pretty(rest, indent, false, acc)

  defp do_pretty([char | rest], indent, false, acc),
    do: do_pretty(rest, indent, false, [char | acc])

  defp open_bracket(rest, indent, bracket, acc) do
    # Peek ahead to check for empty container
    trimmed = Enum.drop_while(rest, &(&1 == " "))

    case trimmed do
      [close | _] when close in ["}", "]"] ->
        do_pretty(trimmed, indent, false, [bracket | acc])

      _ ->
        new_indent = indent + 1
        do_pretty(rest, new_indent, false, [pad(new_indent), "\n", bracket | acc])
    end
  end

  defp close_bracket(rest, indent, bracket, acc) do
    new_indent = max(indent - 1, 0)
    do_pretty(rest, new_indent, false, [bracket, pad(new_indent), "\n" | acc])
  end

  defp pad(level), do: String.duplicate("  ", level)
end
