defmodule Nous.Eval.Guard.CSV do
  @moduledoc false
  # A strict RFC 4180 reader for registry sources: a header row, comma
  # separators, double-quoted fields with `""` escapes and embedded newlines,
  # CRLF or LF records. Returns rows as `header => value` maps.

  @spec parse(binary()) :: {:ok, [%{String.t() => String.t()}]} | {:error, String.t()}
  def parse(body) when is_binary(body) do
    body = String.replace_prefix(body, "\uFEFF", "")

    case records(body, [], [], "") do
      {:ok, [header | rows]} ->
        width = length(header)

        Enum.reduce_while(Enum.with_index(rows, 2), {:ok, []}, fn
          {[""], _line}, acc ->
            {:cont, acc}

          {row, _line}, {:ok, acc} when length(row) == width ->
            {:cont, {:ok, [Map.new(Enum.zip(header, row)) | acc]}}

          {row, line}, _acc ->
            {:halt, {:error, "CSV record #{line} has #{length(row)} fields, the header #{width}"}}
        end)
        |> then(fn
          {:ok, rows} -> {:ok, Enum.reverse(rows)}
          error -> error
        end)

      {:ok, []} ->
        {:ok, []}

      error ->
        error
    end
  end

  # records(rest, finished_records, fields_of_current_record, current_field)
  defp records("", acc, [], ""), do: {:ok, Enum.reverse(acc)}

  defp records("", acc, fields, field),
    do: {:ok, Enum.reverse([Enum.reverse([field | fields]) | acc])}

  defp records("\"" <> rest, acc, fields, "") do
    case quoted(rest, "") do
      {:ok, value, rest} -> after_quoted(rest, acc, fields, value)
      error -> error
    end
  end

  defp records("," <> rest, acc, fields, field), do: records(rest, acc, [field | fields], "")

  defp records("\r\n" <> rest, acc, fields, field),
    do: records(rest, [Enum.reverse([field | fields]) | acc], [], "")

  defp records("\n" <> rest, acc, fields, field),
    do: records(rest, [Enum.reverse([field | fields]) | acc], [], "")

  defp records(<<c::utf8, rest::binary>>, acc, fields, field),
    do: records(rest, acc, fields, <<field::binary, c::utf8>>)

  defp records(_invalid, _acc, _fields, _field), do: {:error, "CSV is not valid UTF-8"}

  defp after_quoted("", acc, fields, value), do: records("", acc, fields, value)
  defp after_quoted("," <> _ = rest, acc, fields, value), do: records(rest, acc, fields, value)
  defp after_quoted("\r\n" <> _ = rest, acc, fields, value), do: records(rest, acc, fields, value)
  defp after_quoted("\n" <> _ = rest, acc, fields, value), do: records(rest, acc, fields, value)
  defp after_quoted(_rest, _acc, _fields, _value), do: {:error, "CSV text after a closing quote"}

  defp quoted("\"\"" <> rest, value), do: quoted(rest, value <> "\"")
  defp quoted("\"" <> rest, value), do: {:ok, value, rest}
  defp quoted(<<c::utf8, rest::binary>>, value), do: quoted(rest, <<value::binary, c::utf8>>)
  defp quoted("", _value), do: {:error, "CSV ends inside a quoted field"}
  defp quoted(_invalid, _value), do: {:error, "CSV is not valid UTF-8"}
end
