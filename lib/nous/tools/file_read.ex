defmodule Nous.Tools.FileRead do
  @moduledoc """
  File reading tool with line numbers.

  Returns file content with `cat -n` style line numbers, supporting
  offset and limit for reading specific sections of large files.

  ## Limits

  The file is streamed line-wise and only the requested window is ever
  materialised, so `offset`/`limit` cost what they select rather than what
  the file weighs. On top of that the rendered output is capped at
  1_000_000 bytes and truncated with a trailing marker. Move the ceiling
  with `ctx.deps[:file_read_max_bytes]` or
  `config :nous, file_read_max_bytes: bytes`.
  """

  use Nous.Tool.Schema

  @default_limit 2000

  # Ceiling on the rendered output, in bytes. `limit` is a *line* count and
  # the model picks it, so nothing bounded the result by size: 2000 lines of
  # a minified bundle is hundreds of megabytes. A megabyte is already far
  # more text than any model context can absorb, so a read that trips this
  # was never going to be useful whole.
  @default_max_bytes 1_000_000

  tool "file_read",
    description: "Read a file from the filesystem. Returns content with line numbers.",
    category: :read do
    param(:file_path, :string, required: true, doc: "Path to the file to read")

    param(:offset, :integer, doc: "Line number to start reading from (1-based). Defaults to 1.")

    param(:limit, :integer, doc: "Number of lines to read. Defaults to 2000.")
  end

  @impl true
  def execute(ctx, %{"file_path" => file_path} = args) do
    offset = Map.get(args, "offset", 1) |> max(1)
    limit = Map.get(args, "limit", @default_limit)

    with {:ok, safe_path} <- Nous.Tools.PathGuard.validate(file_path, ctx),
         {:ok, result} <- read_window(safe_path, offset, limit, max_bytes(ctx)) do
      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to read #{file_path}: #{inspect(reason)}"}
    end
  end

  # Streams the file and renders only the `limit` lines starting at `offset`.
  # File.stream! signals failure by raising where File.read/1 returned a posix
  # tuple, so rescue back into the tuple the caller's error clauses expect.
  defp read_window(path, offset, limit, max_bytes) do
    rendered =
      path
      |> split_lines()
      |> Stream.with_index(1)
      |> Stream.drop(offset - 1)
      |> Stream.take(limit)
      |> Enum.reduce_while({[], 0}, fn {line, num}, {acc, bytes} ->
        rendered = "#{num}\t#{line}"
        separator = if acc == [], do: 0, else: 1
        bytes = bytes + byte_size(rendered) + separator

        if bytes > max_bytes do
          {:halt, {[truncation_marker(max_bytes) | acc], bytes}}
        else
          {:cont, {[rendered | acc], bytes}}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    {:ok, Enum.join(rendered, "\n")}
  rescue
    e in File.Error -> {:error, e.reason}
  end

  defp truncation_marker(max_bytes) do
    "[truncated: output exceeded the #{max_bytes} byte limit]"
  end

  # Reproduces `String.split(content, "\n")` over a stream: every newline is a
  # separator, so a file ending in one yields a final empty element and an
  # empty file yields a single empty element. `File.stream!(:line)` keeps the
  # terminator and emits nothing for either case, hence the `:eof` sentinel —
  # dropping the phantom element would silently renumber every existing read.
  #
  # One deliberate output change: `:file.read_line/1` normalises CRLF to LF,
  # so a DOS-line-ending file no longer renders a stray `\r` at the end of
  # every line the way the whole-file split did.
  defp split_lines(path) do
    path
    |> File.stream!(:line)
    |> Stream.concat([:eof])
    |> Stream.transform(true, fn
      :eof, true -> {[""], false}
      :eof, false -> {[], false}
      line, _pending -> {[String.replace_suffix(line, "\n", "")], String.ends_with?(line, "\n")}
    end)
  end

  # Deps first, then application config — the resolution order used by
  # `Nous.Tools.WebFetch` and `Nous.Tools.Search.Common.api_key/3`.
  defp max_bytes(ctx) do
    positive_int(ctx_deps(ctx)[:file_read_max_bytes]) ||
      positive_int(Application.get_env(:nous, :file_read_max_bytes)) ||
      @default_max_bytes
  end

  defp ctx_deps(%{deps: deps}) when is_map(deps), do: deps
  defp ctx_deps(_ctx), do: %{}

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_other), do: nil
end
