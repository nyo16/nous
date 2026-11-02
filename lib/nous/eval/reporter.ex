defmodule Nous.Eval.Reporter do
  @moduledoc """
  Renders an eval run or a comparison as text.

      Nous.Eval.Reporter.render(run)                        # console text
      Nous.Eval.Reporter.render(comparison, format: :markdown)
      Nous.Eval.Reporter.render(run, format: :json)

  The subject is a `Nous.Eval.Run` (rendered from its `Nous.Eval.Summary`)
  or a `Nous.Eval.Compare` result. Built-in formats:

    * `:console` - `Nous.Eval.Reporter.Console`, plain text with optional
      ANSI colors
    * `:markdown` - `Nous.Eval.Reporter.Markdown`, for PR comments
    * `:json` - `Nous.Eval.Reporter.JSON`, the summary or comparison as
      canonical JSON

  `:format` may also be a module implementing this behaviour. Every
  reporter shows per-scorer metrics, error counts by kind, intervals and the
  minimum detectable effect; none prints traces or agent output.

  A run whose `:summary` already holds a `Nous.Eval.Summary` (its
  `"schema"` key) is rendered from it; otherwise the summary is built from
  the samples.
  """

  alias Nous.Eval.{Compare, Run, Summary}

  @doc "Renders `subject`; `opts` are reporter specific."
  @callback render(subject :: Run.t() | Compare.t(), opts :: keyword()) :: iodata()

  @formats %{
    console: Nous.Eval.Reporter.Console,
    markdown: Nous.Eval.Reporter.Markdown,
    json: Nous.Eval.Reporter.JSON
  }

  @doc """
  Renders `subject` with the reporter named by `opts[:format]` (default
  `:console`); the other options go to the reporter.

  Raises `ArgumentError` for an unknown format.
  """
  @spec render(Run.t() | Compare.t(), keyword()) :: iodata()
  def render(subject, opts \\ []) do
    {format, opts} = Keyword.pop(opts, :format, :console)
    reporter(format).render(subject, opts)
  end

  @doc "The built-in format names."
  @spec formats() :: [atom()]
  def formats, do: @formats |> Map.keys() |> Enum.sort()

  defp reporter(format) when is_map_key(@formats, format), do: Map.fetch!(@formats, format)

  defp reporter(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :render, 2),
      do: module,
      else: raise(ArgumentError, "unknown reporter format: #{inspect(module)}")
  end

  defp reporter(other), do: raise(ArgumentError, "unknown reporter format: #{inspect(other)}")

  # ── Shared by the built-in reporters ────────────────────────────────────

  @doc false
  @spec summary(Run.t()) :: Summary.t()
  def summary(%Run{summary: %{"schema" => schema} = summary} = run) do
    if schema == Summary.schema(), do: summary, else: Summary.build(run)
  end

  def summary(%Run{} = run), do: Summary.build(run)

  @doc false
  # "72.5%"; "n/a" for nil.
  @spec pct(number() | nil) :: String.t()
  def pct(nil), do: "n/a"
  def pct(x), do: fixed(x * 100, 1) <> "%"

  @doc false
  # Signed percentage points: "+5.0 pp", "-12.5 pp".
  @spec pp(number() | nil) :: String.t()
  def pp(nil), do: "n/a"
  def pp(x), do: sign(x) <> fixed(abs(x) * 100, 1) <> " pp"

  @doc false
  # "[60.1%, 80.2%]"
  @spec pct_ci([number()] | {number(), number()} | nil) :: String.t()
  def pct_ci(nil), do: "n/a"
  def pct_ci({lo, hi}), do: pct_ci([lo, hi])
  def pct_ci([lo, hi]), do: "[" <> pct(lo) <> ", " <> pct(hi) <> "]"

  @doc false
  # "[-35.0, +5.0] pp"
  @spec pp_ci([number()] | {number(), number()} | nil) :: String.t()
  def pp_ci(nil), do: "n/a"
  def pp_ci({lo, hi}), do: pp_ci([lo, hi])

  def pp_ci([lo, hi]),
    do:
      "[" <>
        sign(lo) <>
        fixed(abs(lo) * 100, 1) <> ", " <> sign(hi) <> fixed(abs(hi) * 100, 1) <> "] pp"

  @doc false
  @spec p_value(number() | nil) :: String.t()
  def p_value(nil), do: "n/a"
  def p_value(p) when p < 0.001, do: "<0.001"
  def p_value(p), do: fixed(p, 3)

  @doc false
  @spec money(number() | nil) :: String.t()
  def money(nil), do: "n/a"
  def money(x), do: "$" <> fixed(x, 4)

  @doc false
  @spec number(number() | nil, non_neg_integer()) :: String.t()
  def number(nil, _decimals), do: "n/a"
  def number(x, 0), do: x |> round() |> Integer.to_string()
  def number(x, decimals), do: fixed(x, decimals)

  @doc false
  # "+12.0%" relative change; "" when unknown.
  @spec relative(number() | nil) :: String.t()
  def relative(nil), do: ""
  def relative(r), do: sign(r) <> fixed(abs(r) * 100, 1) <> "%"

  @doc false
  # The comparison's per-case rows with `label`, capped at `max`.
  @spec cases_with(Compare.t(), atom(), pos_integer()) :: {[String.t()], non_neg_integer()}
  def cases_with(%Compare{cases: rows}, label, max) do
    ids = for %{label: ^label, id: id} <- rows, do: id
    {Enum.take(ids, max), length(ids)}
  end

  @doc false
  @spec error_changed(Compare.t(), pos_integer()) :: {[String.t()], non_neg_integer()}
  def error_changed(%Compare{cases: rows}, max) do
    ids = for %{error_changed: true, id: id} <- rows, do: id
    {Enum.take(ids, max), length(ids)}
  end

  @doc false
  # Case ids whose scored samples mostly failed or that only errored.
  @spec failing_cases(Summary.t(), pos_integer()) :: {[String.t()], non_neg_integer()}
  def failing_cases(summary, max) do
    ids =
      for %{"status" => s, "id" => id} <- summary["cases"],
          s in ["fail", "mixed", "error"],
          do: id

    {Enum.take(ids, max), length(ids)}
  end

  @doc false
  @spec reason_text(map()) :: String.t()
  def reason_text(%{reason: :error_rate, error_rate: rate, max_error_rate: max}),
    do: "candidate error rate #{pct(rate)} exceeds max_error_rate #{pct(max)}"

  def reason_text(%{reason: :no_comparable_cases}), do: "no comparable cases"
  def reason_text(%{reason: :run_aborted, run: run}), do: "#{run} run was aborted"

  def reason_text(%{reason: :metric_untestable, metric: m, detail: detail}),
    do: "gate metric #{Compare.Metric.name(m)} cannot be tested (#{inspect(detail)})"

  def reason_text(%{reason: :regression, metric: m, delta: delta, adjusted_p_value: p}),
    do: "#{Compare.Metric.name(m)} regressed by #{pp(delta)} (Holm p = #{p_value(p)})"

  defp sign(x) when x < 0, do: "-"
  defp sign(_x), do: "+"

  defp fixed(x, decimals), do: :erlang.float_to_binary(x / 1, decimals: decimals)
end
