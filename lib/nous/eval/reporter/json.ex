defmodule Nous.Eval.Reporter.JSON do
  @moduledoc """
  Machine-readable report: a run's `Nous.Eval.Summary` or a comparison's
  `Nous.Eval.Compare.to_map/1`, encoded with `Nous.Eval.CanonicalJSON`
  (sorted keys, no whitespace), followed by a newline.

  The output never contains traces, agent output or sample-level scorer
  details beyond the summary's capped `"error_examples"`. It takes no
  options.
  """

  @behaviour Nous.Eval.Reporter

  alias Nous.Eval.{CanonicalJSON, Compare, Reporter, Run}

  @impl true
  def render(subject, opts \\ [])
  def render(%Run{} = run, _opts), do: [CanonicalJSON.encode(Reporter.summary(run)), ?\n]
  def render(%Compare{} = c, _opts), do: [CanonicalJSON.encode(Compare.to_map(c)), ?\n]
end
