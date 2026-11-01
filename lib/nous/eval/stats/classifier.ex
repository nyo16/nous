defmodule Nous.Eval.Stats.Classifier do
  @moduledoc """
  Binary classifier metrics for guards and judges.

  "Positive" means the item should be flagged (for a guard: should be
  blocked). Labels are booleans (`true` = positive). Scored items are
  `{score, positive?}` tuples; an item is predicted positive at threshold `t`
  when `score >= t`.

  Rates whose denominator is zero (precision with no predicted positives,
  recall with no positives, FPR with no negatives) are `nil`, never NaN.
  Curve functions return one point per distinct score, in descending
  threshold order; the "flag nothing" operating point, where needed, has
  `threshold: nil`.

  For guard reports pair the false-allow rate (`fnr`) with the false-block
  rate (`fpr`), attach Wilson intervals (`Nous.Eval.Stats.wilson/3`) to both,
  and re-estimate precision at the production prevalence with
  `prevalence_adjusted/3`: precision measured on a balanced corpus does not
  transfer.
  """

  import Nous.Eval.Stats.Guards

  @type scored :: [{number(), boolean()}]

  @type counts :: %{
          tp: non_neg_integer(),
          fp: non_neg_integer(),
          tn: non_neg_integer(),
          fn: non_neg_integer()
        }

  @type metrics :: %{
          precision: float() | nil,
          recall: float() | nil,
          fnr: float() | nil,
          fpr: float() | nil,
          specificity: float() | nil,
          accuracy: float() | nil,
          prevalence: float() | nil,
          f_beta: float() | nil,
          beta: float()
        }

  @doc """
  Confusion counts from `{predicted?, actual?}` boolean pairs. An empty list
  gives all-zero counts.

  ## Examples

      iex> Nous.Eval.Stats.Classifier.confusion([{true, true}, {true, false}, {false, false}, {false, true}, {true, true}])
      {:ok, %{tp: 2, fp: 1, tn: 1, fn: 1}}
  """
  @spec confusion([{boolean(), boolean()}]) :: {:ok, counts()} | {:error, :invalid_values}
  def confusion(pairs) when is_list(pairs) do
    if Enum.all?(pairs, &boolean_pair?/1) do
      {:ok,
       Enum.reduce(pairs, %{tp: 0, fp: 0, tn: 0, fn: 0}, fn
         {true, true}, acc -> Map.update!(acc, :tp, &(&1 + 1))
         {true, false}, acc -> Map.update!(acc, :fp, &(&1 + 1))
         {false, false}, acc -> Map.update!(acc, :tn, &(&1 + 1))
         {false, true}, acc -> Map.update!(acc, :fn, &(&1 + 1))
       end)}
    else
      {:error, :invalid_values}
    end
  end

  def confusion(_), do: {:error, :invalid_values}

  defp boolean_pair?({p, a}) when is_boolean(p) and is_boolean(a), do: true
  defp boolean_pair?(_), do: false

  @doc """
  Confusion counts of scored items at `threshold` (`score >= threshold` is
  predicted positive).
  """
  @spec confusion_at(scored(), number()) :: {:ok, counts()} | {:error, :invalid_values}
  def confusion_at(scored, threshold) when is_number(threshold) do
    with :ok <- check_scored(scored) do
      scored
      |> Enum.map(fn {score, positive?} -> {score >= threshold, positive?} end)
      |> confusion()
    end
  end

  def confusion_at(_scored, _threshold), do: {:error, :invalid_values}

  @doc """
  Rates from confusion counts: precision, recall (TPR), false-negative rate
  (`fnr`, a guard's false-allow rate), false-positive rate (`fpr`, a guard's
  false-block rate), specificity, accuracy, prevalence and F-beta.

  F-beta is `(1 + β²)·P·R / (β²·P + R)`; `nil` when precision or recall is
  undefined and `0.0` when both are zero.

  Options: `:beta` (> 0, default `1.0`).

  ## Examples

      iex> {:ok, m} = Nous.Eval.Stats.Classifier.metrics(%{tp: 8, fp: 2, tn: 85, fn: 5})
      iex> {m.precision, m.recall, Float.round(m.f_beta, 4)}
      {0.8, 0.6153846153846154, 0.6957}
  """
  @spec metrics(counts(), keyword()) ::
          {:ok, metrics()} | {:error, :invalid_counts | {:invalid_option, :beta}}
  def metrics(counts, opts \\ [])

  def metrics(%{tp: tp, fp: fp, tn: tn, fn: fneg}, opts)
      when is_count(tp) and is_count(fp) and is_count(tn) and is_count(fneg) do
    case Keyword.get(opts, :beta, 1.0) do
      beta when is_number(beta) and beta > 0 ->
        precision = ratio(tp, tp + fp)
        recall = ratio(tp, tp + fneg)
        total = tp + fp + tn + fneg

        {:ok,
         %{
           precision: precision,
           recall: recall,
           fnr: ratio(fneg, tp + fneg),
           fpr: ratio(fp, fp + tn),
           specificity: ratio(tn, fp + tn),
           accuracy: ratio(tp + tn, total),
           prevalence: ratio(tp + fneg, total),
           f_beta: f_beta(precision, recall, beta),
           beta: beta / 1
         }}

      _ ->
        {:error, {:invalid_option, :beta}}
    end
  end

  def metrics(_counts, _opts), do: {:error, :invalid_counts}

  defp f_beta(nil, _r, _beta), do: nil
  defp f_beta(_p, nil, _beta), do: nil
  defp f_beta(p, r, _beta) when p == 0 and r == 0, do: 0.0
  defp f_beta(p, r, beta), do: (1 + beta * beta) * p * r / (beta * beta * p + r)

  @doc """
  Area under the ROC curve in its rank (Mann–Whitney) form: the probability
  that a random positive scores above a random negative, ties counting ½
  (mid-ranks).

  Needs at least one positive and one negative (`{:error, :single_class}`).

  ## Examples

      iex> Nous.Eval.Stats.Classifier.roc_auc([{0.9, true}, {0.8, false}, {0.7, true}, {0.1, false}])
      {:ok, 0.75}
  """
  @spec roc_auc(scored()) :: {:ok, float()} | {:error, :single_class | :invalid_values}
  def roc_auc(scored) do
    with :ok <- check_scored(scored),
         {:ok, pos, neg} <- class_totals(scored, :both) do
      rank_sum =
        scored
        |> normalize()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.chunk_by(&elem(&1, 0))
        |> Enum.reduce({0, 0.0}, fn group, {before, sum} ->
          size = length(group)
          mid_rank = before + (size + 1) / 2
          {before + size, sum + mid_rank * Enum.count(group, &elem(&1, 1))}
        end)
        |> elem(1)

      {:ok, (rank_sum - pos * (pos + 1) / 2) / (pos * neg)}
    end
  end

  @doc """
  ROC points `%{threshold, tpr, fpr}` from the "flag nothing" point
  (`threshold: nil`, `tpr: 0.0`, `fpr: 0.0`) down to the lowest score.

  Needs both classes (`{:error, :single_class}`).
  """
  @spec roc_curve(scored()) ::
          {:ok, [%{threshold: number() | nil, tpr: float(), fpr: float()}]}
          | {:error, :single_class | :invalid_values}
  def roc_curve(scored) do
    with :ok <- check_scored(scored),
         {:ok, pos, neg} <- class_totals(scored, :both) do
      points =
        Enum.map([{nil, 0, 0} | cumulative(scored)], fn {t, tp, fp} ->
          %{threshold: t, tpr: tp / pos, fpr: fp / neg}
        end)

      {:ok, points}
    end
  end

  @doc """
  Precision–recall points `%{threshold, precision, recall}`, one per distinct
  score in descending order.

  Needs at least one positive (`{:error, :no_positives}`).
  """
  @spec pr_curve(scored()) ::
          {:ok, [%{threshold: number(), precision: float(), recall: float()}]}
          | {:error, :no_positives | :invalid_values}
  def pr_curve(scored) do
    with :ok <- check_scored(scored),
         {:ok, pos, _neg} <- class_totals(scored, :positives) do
      {:ok,
       Enum.map(cumulative(scored), fn {t, tp, fp} ->
         %{threshold: t, precision: tp / (tp + fp), recall: tp / pos}
       end)}
    end
  end

  @doc """
  Average precision, `Σ_n (R_n − R_{n−1})·P_n` over the PR points in
  descending threshold order (the step-wise area without interpolation;
  the definition of scikit-learn's `average_precision_score`). Llama Guard
  reports it (AUPRC) as its primary metric.

  Needs at least one positive (`{:error, :no_positives}`).

  ## Examples

      iex> Nous.Eval.Stats.Classifier.average_precision([{0.9, true}, {0.8, false}, {0.7, true}, {0.1, false}])
      {:ok, 0.8333333333333333}
  """
  @spec average_precision(scored()) :: {:ok, float()} | {:error, :no_positives | :invalid_values}
  def average_precision(scored) do
    with {:ok, points} <- pr_curve(scored) do
      {ap, _} =
        Enum.reduce(points, {0.0, 0.0}, fn %{precision: p, recall: r}, {ap, prev_r} ->
          {ap + (r - prev_r) * p, r}
        end)

      {:ok, ap}
    end
  end

  @doc """
  Highest recall reachable with a false-positive rate of at most `max_fpr`,
  and the highest threshold that reaches it (Prompt Guard 2 reports
  "Recall @ 1% FPR").

  FPR moves in steps of `1 / negatives`: with fewer than `1 / max_fpr`
  negatives the only admissible point may be "flag nothing"
  (`threshold: nil`, `recall: 0.0`). Needs both classes.

  ## Examples

      iex> scored = [{0.9, true}, {0.8, false}, {0.7, true}, {0.1, false}]
      iex> Nous.Eval.Stats.Classifier.recall_at_fpr(scored, 0.5)
      {:ok, %{recall: 1.0, fpr: 0.5, threshold: 0.7}}
  """
  @spec recall_at_fpr(scored(), number()) ::
          {:ok, %{recall: float(), fpr: float(), threshold: number() | nil}}
          | {:error, :single_class | :invalid_values | {:invalid_option, :max_fpr}}
  def recall_at_fpr(scored, max_fpr) when is_unit(max_fpr) do
    with {:ok, points} <- roc_curve(scored) do
      best =
        points
        |> Enum.filter(&(&1.fpr <= max_fpr))
        |> Enum.reduce(fn point, best -> if point.tpr > best.tpr, do: point, else: best end)

      {:ok, %{recall: best.tpr, fpr: best.fpr, threshold: best.threshold}}
    end
  end

  def recall_at_fpr(_scored, _max_fpr), do: {:error, {:invalid_option, :max_fpr}}

  @doc """
  Confusion counts and rates at every distinct score threshold, highest
  first. Each entry has `:threshold`, `:tp`, `:fp`, `:tn`, `:fn` and the
  `metrics/2` keys `:precision`, `:recall`, `:fpr`, `:f_beta`.

  Single-class data is allowed (the undefined rates are `nil`).

  Options: `:beta` (default `1.0`).
  """
  @spec threshold_sweep(scored(), keyword()) ::
          {:ok, [map()]} | {:error, :empty | :invalid_values | {:invalid_option, :beta}}
  def threshold_sweep(scored, opts \\ []) do
    with :ok <- check_scored(scored),
         :ok <- if(scored == [], do: {:error, :empty}, else: :ok),
         {:ok, pos, neg} <- class_totals(scored, :any) do
      Enum.reduce_while(cumulative(scored), {:ok, []}, fn {t, tp, fp}, {:ok, acc} ->
        counts = %{tp: tp, fp: fp, tn: neg - fp, fn: pos - tp}

        case metrics(counts, opts) do
          {:ok, m} ->
            row =
              counts
              |> Map.merge(Map.take(m, [:precision, :recall, :fpr, :f_beta]))
              |> Map.put(:threshold, t)

            {:cont, {:ok, [row | acc]}}

          error ->
            {:halt, error}
        end
      end)
      |> then(fn
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        error -> error
      end)
    end
  end

  @doc """
  Threshold minimising the expected misclassification cost per item,
  `cost_fn·π·FNR + cost_fp·(1 − π)·FPR`, over every distinct score and the
  "flag nothing" point (`threshold: nil`). Ties go to the higher threshold.

  Options:

    * `:cost_fp` - cost of a false positive (false block), default `1.0`
    * `:cost_fn` - cost of a false negative (false allow), default `1.0`
    * `:prevalence` - expected production share of positives π in
      `[0, 1]`; defaults to the share in `scored`

  Needs both classes.

  ## Examples

      iex> scored = [{0.9, true}, {0.8, false}, {0.7, true}, {0.1, false}]
      iex> {:ok, r} = Nous.Eval.Stats.Classifier.cost_weighted_threshold(scored, cost_fn: 5.0)
      iex> {r.threshold, r.expected_cost}
      {0.7, 0.25}
  """
  @spec cost_weighted_threshold(scored(), keyword()) ::
          {:ok,
           %{threshold: number() | nil, expected_cost: float(), recall: float(), fpr: float()}}
          | {:error,
             :single_class
             | :invalid_values
             | {:invalid_option, :cost_fp | :cost_fn | :prevalence}}
  def cost_weighted_threshold(scored, opts \\ []) do
    with {:ok, points} <- roc_curve(scored),
         {:ok, cost_fp} <- cost_opt(opts, :cost_fp),
         {:ok, cost_fn} <- cost_opt(opts, :cost_fn),
         {:ok, prevalence} <- prevalence_opt(opts, scored) do
      points
      |> Enum.map(fn %{threshold: t, tpr: tpr, fpr: fpr} ->
        cost = cost_fn * prevalence * (1 - tpr) + cost_fp * (1 - prevalence) * fpr
        %{threshold: t, expected_cost: cost, recall: tpr, fpr: fpr}
      end)
      |> Enum.reduce(fn point, best ->
        if point.expected_cost < best.expected_cost, do: point, else: best
      end)
      |> then(&{:ok, &1})
    end
  end

  defp cost_opt(opts, key) do
    case Keyword.get(opts, key, 1.0) do
      c when is_number(c) and c >= 0 -> {:ok, c / 1}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp prevalence_opt(opts, scored) do
    case Keyword.fetch(opts, :prevalence) do
      {:ok, p} when is_unit(p) -> {:ok, p / 1}
      {:ok, _} -> {:error, {:invalid_option, :prevalence}}
      :error -> {:ok, Enum.count(scored, &elem(&1, 1)) / length(scored)}
    end
  end

  @doc """
  Predictive values re-estimated at prevalence `π` from the
  prevalence-independent rates TPR (recall) and FPR:

  `PPV(π) = TPR·π / (TPR·π + FPR·(1 − π))`,
  `NPV(π) = (1 − FPR)(1 − π) / ((1 − FPR)(1 − π) + (1 − TPR)·π)`.

  A value whose denominator is zero is `nil`. For a conservative interval,
  plug the Wilson bounds of TPR and FPR into these monotone formulas.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.Classifier.prevalence_adjusted(0.9, 0.05, 0.01)
      iex> Float.round(r.ppv, 3)
      0.154
  """
  @spec prevalence_adjusted(number(), number(), number()) ::
          {:ok, %{ppv: float() | nil, npv: float() | nil}}
          | {:error, {:invalid_option, :tpr | :fpr | :prevalence}}
  def prevalence_adjusted(tpr, fpr, prevalence) do
    cond do
      not is_unit(tpr) ->
        {:error, {:invalid_option, :tpr}}

      not is_unit(fpr) ->
        {:error, {:invalid_option, :fpr}}

      not is_unit(prevalence) ->
        {:error, {:invalid_option, :prevalence}}

      true ->
        tp = tpr * prevalence
        fp = fpr * (1 - prevalence)
        tn = (1 - fpr) * (1 - prevalence)
        fneg = (1 - tpr) * prevalence
        {:ok, %{ppv: ratio(tp, tp + fp), npv: ratio(tn, tn + fneg)}}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp check_scored(scored) when is_list(scored) do
    if Enum.all?(scored, &scored_item?/1), do: :ok, else: {:error, :invalid_values}
  end

  defp check_scored(_), do: {:error, :invalid_values}

  defp scored_item?({s, label}) when is_number(s) and is_boolean(label), do: true
  defp scored_item?(_), do: false

  defp class_totals(scored, need) do
    pos = Enum.count(scored, &elem(&1, 1))
    neg = length(scored) - pos

    cond do
      need == :both and (pos == 0 or neg == 0) -> {:error, :single_class}
      need == :positives and pos == 0 -> {:error, :no_positives}
      true -> {:ok, pos, neg}
    end
  end

  # [{threshold, tp, fp}] at each distinct score, descending.
  defp cumulative(scored) do
    scored
    |> normalize()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map_reduce({0, 0}, fn [{t, _} | _] = group, {tp, fp} ->
      gp = Enum.count(group, &elem(&1, 1))
      tp = tp + gp
      fp = fp + length(group) - gp
      {{t, tp, fp}, {tp, fp}}
    end)
    |> elem(0)
  end

  # Scores that compare equal must form one threshold: 1 and 1.0, and -0.0
  # and 0.0 (adding +0.0 turns -0.0 into 0.0).
  defp normalize(scored), do: Enum.map(scored, fn {s, label} -> {s / 1 + 0.0, label} end)

  defp ratio(_num, den) when den == 0, do: nil
  defp ratio(num, den), do: num / den
end
