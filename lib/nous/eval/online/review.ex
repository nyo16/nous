defmodule Nous.Eval.Online.Review do
  @moduledoc """
  The review queue of promoted guard cases: a `nous.guard_case/1` JSONL file
  whose unlabelled lines (`"label": null`) wait for a human.

  `Nous.Eval.promote/3` with `as: {:guard_case, surface: ...}` appends
  lines with `label: null` and `provenance.review: "pending"`; a dataset
  validator leaves them out of calibration. `pending/1` lists them in
  review order, `label/5` records a human decision:

      {:ok, [first | _]} = Nous.Eval.Online.Review.pending("guards/online.jsonl")
      :ok = Nous.Eval.Online.Review.label("guards/online.jsonl", first["id"], "block", "alice")

  The file is the queue (one reviewer per file); every write replaces it
  through a temporary file and a rename. `mix nous.eval.promote --label`
  does the same from the command line.
  """

  alias Nous.Eval.Online.Promote

  @labels ["block", "allow"]

  # Escalations and denials first: the guard was unsure or acted, and a
  # wrong call there costs the most.
  @priority %{"escalate" => 0, "deny" => 1, "allow" => 2}

  @doc """
  The unlabelled cases of `path`, decoded, escalated and denied ones first
  (by the guard's observed verdict), then in file order.
  """
  @spec pending(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def pending(path) do
    with {:ok, records} <- records(path) do
      {:ok,
       records
       |> Enum.with_index()
       |> Enum.filter(fn {record, _i} -> pending?(record) end)
       |> Enum.sort_by(fn {record, i} -> {priority(record), i} end)
       |> Enum.map(&elem(&1, 0))}
    end
  end

  @doc """
  Labels the case `id` of `path` with `label` (`"block"` or `"allow"`):
  sets `provenance.label_source: "promoted_reviewed"`, `provenance.review:
  "approved"` and `provenance.reviewed: {"by": reviewer, "at": iso8601}`.

  Options: `:at` - the review time (default now).

  Errors: `{:error, :not_found}`, `{:error, {:invalid_label, label}}`,
  `{:error, :invalid_reviewer}`.
  """
  @spec label(Path.t(), String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def label(path, id, label, reviewer, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)

    cond do
      label not in @labels ->
        {:error, {:invalid_label, label}}

      not (is_binary(reviewer) and String.trim(reviewer) != "") ->
        {:error, :invalid_reviewer}

      true ->
        with {:ok, lines} <- Promote.read_lines(path),
             {:ok, lines} <- relabel(lines, id, label, reviewer, at) do
          Promote.write_lines(path, lines)
        end
    end
  end

  defp relabel(lines, id, label, reviewer, at) do
    {lines, found?} =
      Enum.map_reduce(lines, false, fn line, found? ->
        case JSON.decode(line) do
          {:ok, %{"id" => ^id} = record} ->
            {Nous.Eval.CanonicalJSON.encode(apply_label(record, label, reviewer, at)), true}

          _ ->
            {line, found?}
        end
      end)

    if found?, do: {:ok, lines}, else: {:error, :not_found}
  end

  defp apply_label(record, label, reviewer, at) do
    provenance =
      record
      |> Map.get("provenance", %{})
      |> Map.merge(%{
        "label_source" => "promoted_reviewed",
        "review" => "approved",
        "reviewed" => %{"by" => reviewer, "at" => DateTime.to_iso8601(at)}
      })

    Map.merge(record, %{"label" => label, "provenance" => provenance})
  end

  defp records(path) do
    with {:ok, lines} <- Promote.read_lines(path) do
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case JSON.decode(line) do
          {:ok, %{} = record} -> {:cont, {:ok, [record | acc]}}
          _ -> {:halt, {:error, {:invalid_line, line}}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end
    end
  end

  defp pending?(%{"label" => nil}), do: true
  defp pending?(_record), do: false

  defp priority(record) do
    verdict = get_in(record, ["provenance", "promoted_from", "observed_verdict"])
    Map.get(@priority, verdict, 3)
  end
end
