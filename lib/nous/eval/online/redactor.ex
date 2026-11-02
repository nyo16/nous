defmodule Nous.Eval.Online.Redactor do
  @moduledoc """
  Behaviour for the redactor `Nous.Eval.Online` requires (`redact:`).

  A redactor receives a `Nous.Eval.Online.Content` and returns it with
  content values replaced. It runs in its own process with a time limit
  (`redact_timeout`), sees a copy of one captured trace, and must be pure
  and fast: same input, same output, no I/O.

      defmodule MyApp.TraceRedactor do
        @behaviour Nous.Eval.Online.Redactor

        @email ~r/[\\w.+-]+@[\\w-]+\\.[\\w.]+/

        @impl true
        def redact(content),
          do: Nous.Eval.Online.Redactor.map_text(content, &Regex.replace(@email, &1, "[email]"))

        @impl true
        def version, do: "1"
      end

  `redact:` also accepts a 1-arity function, or `:drop_content` (no
  content is kept at all: only the skeleton is stored).

  ## What Nous enforces

  After `redact/1` returns, the result must be a `Nous.Eval.Online.Content`
  with the same `trace_id`, the same skeleton and the same set of paths,
  and every value must be JSON (strings, numbers, booleans, `nil`, lists,
  string-keyed maps) or `:redacted`, and must decode as Codec JSON. On a
  raise, throw, exit, timeout or any violation the sample is stored
  **without content** (the skeleton only), marked `redaction: "failed"`
  with the failure kind; the exception and its message are never kept or
  logged, because they may quote the content. Kinds: `:raised`, `:thrown`,
  `:exited`, `:timeout`, `:invalid_return`, `:trace_id_changed`,
  `:skeleton_changed`, `:keys_changed`, `:not_json`, `:undecodable`.

  Nous ships no default redactor: what is sensitive is the application's
  call. `map_text/2` is a helper for writing one, never applied on its own.
  """

  alias Nous.Eval.Online.{Content, Redaction}

  @callback redact(Content.t()) :: Content.t()
  @callback version() :: String.t()

  @optional_callbacks version: 0

  @type t :: :drop_content | (Content.t() -> Content.t()) | module()

  # Codec tags whose payload is structure, not text.
  @structural_tags ["$atom", "$dt", "$ndt", "$date", "$time", "$usage"]

  # Message fields that hold text; `role`, `tool_call_id` and `created_at`
  # are structure.
  @message_text_fields ["content", "reasoning_content", "tool_calls", "metadata", "name"]

  @doc """
  Applies `fun` to every text leaf of every content value and returns the
  content.

  Text leaves are plain strings, the keys of plain JSON objects, the text
  fields of a `{"$msg": ...}` message (`content`, `reasoning_content`,
  `tool_calls`, `metadata` - so `metadata.content_parts` too - and `name`),
  the `content` of a `{"$part": ...}` content part, and the text of an
  `{"$opaque": ...}` term. Codec structure (`$atom`, timestamps, `$usage`,
  message roles) is left alone, so the value still decodes. A
  `{"$bin": ...}` binary that is not UTF-8 is replaced by `:redacted`.
  `fun` must return a string; keys that it maps to the same string merge.
  """
  @spec map_text(Content.t(), (String.t() -> String.t())) :: Content.t()
  def map_text(%Content{fields: fields} = content, fun) when is_function(fun, 1) do
    %Content{content | fields: Map.new(fields, fn {path, value} -> {path, walk(value, fun)} end)}
  end

  defp walk(value, fun) when is_binary(value), do: fun.(value)
  defp walk(value, fun) when is_list(value), do: Enum.map(value, &walk(&1, fun))

  defp walk(%{} = map, fun) when map_size(map) == 1 do
    case Map.to_list(map) do
      [{"$" <> _ = tag, inner}] -> walk_tagged(tag, inner, fun)
      [{key, inner}] -> %{walk(key, fun) => walk(inner, fun)}
    end
  end

  defp walk(%{} = map, fun), do: Map.new(map, fn {k, v} -> {walk(k, fun), walk(v, fun)} end)
  defp walk(value, _fun), do: value

  defp walk_tagged(tag, inner, _fun) when tag in @structural_tags, do: %{tag => inner}

  defp walk_tagged("$msg", %{} = fields, fun) do
    %{
      "$msg" =>
        Map.new(fields, fn
          {key, value} when key in @message_text_fields -> {key, walk(value, fun)}
          other -> other
        end)
    }
  end

  defp walk_tagged("$part", %{} = part, fun),
    do: %{"$part" => Map.update(part, "content", nil, &walk(&1, fun))}

  defp walk_tagged("$amap", %{} = map, fun),
    do: %{"$amap" => Map.new(map, fn {k, v} -> {k, walk(v, fun)} end)}

  defp walk_tagged("$map", pairs, fun) when is_list(pairs),
    do: %{"$map" => Enum.map(pairs, &walk(&1, fun))}

  defp walk_tagged("$tuple", items, fun) when is_list(items),
    do: %{"$tuple" => Enum.map(items, &walk(&1, fun))}

  defp walk_tagged("$struct", [module, fields], fun),
    do: %{"$struct" => [module, walk(fields, fun)]}

  defp walk_tagged("$opaque", text, fun) when is_binary(text), do: %{"$opaque" => fun.(text)}
  defp walk_tagged("$bin", _b64, _fun), do: :redacted
  defp walk_tagged(tag, inner, fun), do: %{tag => walk(inner, fun)}

  @doc """
  Checks `redactor` on `content` the way `Nous.Eval.Online` applies it, and
  that it is deterministic (two calls give the same result). Use it in the
  application's tests with a realistic content.

  Returns `{:ok, redacted}` or `{:error, kind}` (the failure kinds of the
  moduledoc, or `:nondeterministic`).
  """
  @spec check(t(), Content.t(), keyword()) :: {:ok, Content.t()} | {:error, atom()}
  def check(redactor, %Content{} = content, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    supervisor = Keyword.get(opts, :supervisor, Nous.TaskSupervisor)

    with {:ok, first, _status} <- Redaction.redact(redactor, content, timeout, supervisor),
         {:ok, second, _status} <- Redaction.redact(redactor, content, timeout, supervisor) do
      if first == second, do: {:ok, first}, else: {:error, :nondeterministic}
    end
  end
end
