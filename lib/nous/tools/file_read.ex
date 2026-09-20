defmodule Nous.Tools.FileRead do
  @moduledoc """
  File reading tool with line numbers.

  Returns file content with `cat -n` style line numbers, supporting
  offset and limit for reading specific sections of large files.
  """

  use Nous.Tool.Schema

  @default_limit 2000
  # Most lines one call may return. At the 10 MB file cap a 1-byte-per-line
  # file has ~10M lines; without this a `limit: 10_000_000` request is legal
  # and lands the whole file in context.
  @max_limit 20_000

  # Whole-file byte cap. `file_read` is on the `@never_spill_tools` list in
  # Nous.AgentRunner.ToolExecution, so whatever it returns lands in the tool
  # result path verbatim, and the window below is streamed precisely so that
  # an `offset`/`limit` read never needs the whole file in memory. The cap
  # keeps a pathological 200 MB file from being walked line by line on every
  # call; a file this large is not something a model should page through.
  @max_file_bytes 10 * 1024 * 1024

  # Read granularity for the streamed window. A window near the top costs a
  # handful of reads; a deep `offset` still scans the prefix, but chunk by
  # chunk, never holding it.
  @chunk_bytes 64 * 1024

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
    # Both are model-supplied. A negative `limit` would turn `Enum.take/2` into
    # "last N lines" and materialise the whole window to get there; the cap
    # keeps a "read everything" request bounded (the tool is never spilled).
    limit = Map.get(args, "limit", @default_limit) |> max(0) |> min(@max_limit)

    with {:ok, safe_path} <- Nous.PathGuard.validate(file_path, ctx),
         {:ok, %File.Stat{size: size}} <- File.stat(safe_path),
         :ok <- check_size(size),
         {:ok, lines} <- read_window(safe_path, offset, limit) do
      {:ok, Enum.map_join(lines, "\n", fn {line, num} -> "#{num}\t#{line}" end)}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to read #{file_path}: #{inspect(reason)}"}
    end
  end

  defp check_size(size) when size <= @max_file_bytes, do: :ok

  defp check_size(size) do
    {:error,
     "file is #{size} bytes, over the 10 MB cap (#{@max_file_bytes} bytes) for file_read; " <>
       "read a narrower range with a different tool (e.g. bash `sed -n 'START,ENDp'`) " <>
       "or split the file"}
  end

  # Streams `[{line, number}]` for the requested window without materialising
  # the file. Chunks are split on "\n" by hand rather than via `:line` mode
  # because `:file.read_line/1` silently drops the "\r" of a CRLF pair; the
  # element sequence here is exactly what `String.split(content, "\n")` would
  # produce (lines without their terminator, plus a trailing "" when the file
  # ends in a newline or is empty), so the rendered output is byte-identical
  # to the pre-streaming implementation.
  defp read_window(path, offset, limit) do
    lines =
      path
      |> File.stream!(@chunk_bytes)
      |> Stream.transform(fn -> "" end, &split_chunk/2, &last_line/1, fn _ -> :ok end)
      |> Stream.drop(offset - 1)
      |> Stream.with_index(offset)
      |> Enum.take(limit)

    {:ok, lines}
  rescue
    # File.stream! only surfaces open failures (eisdir, eacces, ...) when the
    # stream is reduced; map them to the same `{:error, posix}` File.read gave.
    e in File.Error -> {:error, e.reason}
  end

  # `rest` is the unterminated tail carried over from the previous chunk.
  defp split_chunk(chunk, rest) do
    case :binary.split(chunk, "\n", [:global]) do
      [only] ->
        {[], rest <> only}

      [first | more] ->
        {complete, [tail]} = Enum.split(more, -1)
        {[rest <> first | complete], tail}
    end
  end

  defp last_line(rest), do: {[rest], :done}
end
