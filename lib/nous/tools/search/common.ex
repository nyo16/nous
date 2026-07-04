defmodule Nous.Tools.Search.Common do
  @moduledoc """
  Shared plumbing for search tools (Brave, Tavily, ...).

  Owns the pieces every search tool repeats: API-key resolution, query
  extraction, the success/error result envelope, and response-to-result
  field mapping.
  """

  require Logger

  @doc """
  Resolve an API key: context deps first, then application config under
  `:nous`, then the system environment.
  """
  @spec api_key(Nous.RunContext.t(), atom(), String.t()) :: String.t() | nil
  def api_key(ctx, key, env_var) do
    ctx.deps[key] || Application.get_env(:nous, key) || System.get_env(env_var)
  end

  @doc """
  Extract the query from tool args, accepting `"query"` or `"q"`.
  """
  @spec query(map()) :: String.t()
  def query(args), do: Map.get(args, "query") || Map.get(args, "q") || ""

  @doc """
  Run a search behind the standard result envelope.

  When `api_key` is missing or empty, returns the failure envelope with
  `opts[:missing_key_error]` without invoking `fun`. Otherwise `fun` must
  return `{:ok, envelope_map}` (merged with `query` and `success: true`) or
  `{:error, reason}` (logged under `opts[:log_label]`, wrapped with
  `opts[:error_prefix]`).
  """
  @spec run_search(String.t(), String.t() | nil, keyword(), (-> {:ok, map()} | {:error, term()})) ::
          map()
  def run_search(query, api_key, opts, fun) do
    if api_key in [nil, ""] do
      %{query: query, error: Keyword.fetch!(opts, :missing_key_error), success: false}
    else
      case fun.() do
        {:ok, envelope} when is_map(envelope) ->
          envelope
          |> Map.put(:query, query)
          |> Map.put(:success, true)

        {:error, reason} ->
          Logger.error("#{Keyword.fetch!(opts, :log_label)} failed: #{inspect(reason)}")

          %{
            query: query,
            error: "#{Keyword.fetch!(opts, :error_prefix)}: #{inspect(reason)}",
            success: false
          }
      end
    end
  end

  @doc """
  Map raw API result maps to the tool's result shape.

  `fields` is a keyword list of `output_key: "source_key"` or
  `output_key: {"source_key", default}`. Non-list input yields `[]` so a
  malformed response can't crash the tool.
  """
  @spec map_results(term(), keyword()) :: [map()]
  def map_results(results, fields) when is_list(results) do
    Enum.map(results, fn result ->
      Map.new(fields, fn
        {key, {source, default}} -> {key, Map.get(result, source, default)}
        {key, source} when is_binary(source) -> {key, Map.get(result, source)}
      end)
    end)
  end

  def map_results(_results, _fields), do: []
end
