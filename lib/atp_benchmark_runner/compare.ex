defmodule AtpBenchmarkRunner.Compare do
  @moduledoc """
  Longitudinal comparison between two benchmark runs.

  Returns `:new_solves`, `:regressions`, `:only_left`, `:only_right`,
  `:status_changes`, and `:per_prover_solve_deltas`.

  Accepts raw results or local-DB records.
  """

  alias AtpBenchmarkRunner.{Provers, Result}

  @doc """
  Compares two result lists (or local-DB record lists) and returns a diff map.
  """
  @spec diff([Result.t() | map()], [Result.t() | map()], keyword()) :: map()
  def diff(left_results, right_results, opts \\ [])
      when is_list(left_results) and is_list(right_results) do
    left = index_by_problem_prover(left_results)
    right = index_by_problem_prover(right_results)

    our_prover = Keyword.get(opts, :our_prover, Provers.our_prover())
    problem_ids = problem_union(left, right)

    per_problem =
      problem_ids
      |> Enum.sort()
      |> Enum.map(&build_problem_diff(&1, left, right, our_prover))

    %{
      generated_at:
        Keyword.get(
          opts,
          :generated_at,
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        ),
      left_run_id: run_id_from_results(left_results),
      right_run_id: run_id_from_results(right_results),
      our_prover: our_prover,
      per_problem: per_problem,
      per_prover_solve_deltas: solve_deltas(left, right),
      new_solves: Enum.filter(per_problem, &(&1.change == :new_solve)),
      regressions: Enum.filter(per_problem, &(&1.change == :regression)),
      only_left: Enum.filter(per_problem, &(&1.left_status != nil and &1.right_status == nil)),
      only_right: Enum.filter(per_problem, &(&1.right_status != nil and &1.left_status == nil)),
      status_changes: Enum.filter(per_problem, &(&1.change == :status_change))
    }
  end

  @doc """
  Renders the diff as a Markdown summary suitable for the morning report.
  """
  @spec markdown(map()) :: binary()
  def markdown(diff) when is_map(diff) do
    header = [
      "## ATP benchmark run diff",
      "",
      "- Baseline: `#{diff.left_run_id || "n/a"}`",
      "- Current:  `#{diff.right_run_id || "n/a"}`",
      "- Generated: `#{diff.generated_at}`",
      "- New solves: **#{length(diff.new_solves)}**",
      "- Regressions: **#{length(diff.regressions)}**",
      "- Status changes: **#{length(diff.status_changes)}**",
      ""
    ]

    per_prover_table =
      diff.per_prover_solve_deltas
      |> Enum.map_join("\n", fn row ->
        delta = row.right_solved - row.left_solved

        delta_str =
          cond do
            delta > 0 -> "+#{delta}"
            delta < 0 -> "#{delta}"
            true -> "0"
          end

        "| #{row.prover} | #{row.left_solved} | #{row.right_solved} | #{delta_str} |"
      end)

    new_block =
      diff.new_solves
      |> Enum.take(20)
      |> Enum.map_join("\n", &"- `#{&1.problem_id}` (`#{inspect(&1.prover)}`)")
      |> blank_to_message("No new solves vs baseline.")

    reg_block =
      diff.regressions
      |> Enum.take(20)
      |> Enum.map_join("\n", &"- `#{&1.problem_id}` (`#{inspect(&1.prover)}`)")
      |> blank_to_message("No regressions vs baseline.")

    (header ++
       [
         "### Per-prover solve counts",
         "",
         "| Prover | Baseline | Current | Δ |",
         "|---|---:|---:|---:|",
         per_prover_table,
         "",
         "### New solves",
         new_block,
         "",
         "### Regressions",
         reg_block
       ])
    |> Enum.join("\n")
  end

  # --- indexing helpers ---

  defp index_by_problem_prover(results) do
    Enum.reduce(results, %{}, fn record, acc ->
      normalized = normalize_record(record)
      key = {normalized.problem_id, normalized.prover}
      Map.put(acc, key, normalized)
    end)
  end

  defp normalize_record(%Result{} = result) do
    %{
      problem_id: result.problem_id,
      prover: result.prover,
      szs_status: result.szs_status,
      solved: Result.solved?(result)
    }
  end

  defp normalize_record(record) when is_map(record) do
    problem_id =
      Map.get(record, :problem_id) || Map.get(record, "problem_id") || raise("missing problem_id")

    prover = Map.get(record, :prover) || Map.get(record, "prover") || raise("missing prover")
    szs_status = Map.get(record, :szs_status) || Map.get(record, "szs_status")
    solved = Map.get(record, :solved) || Map.get(record, "solved") || result_solved?(szs_status)

    %{
      problem_id: to_string(problem_id),
      prover: prover,
      szs_status: szs_status,
      solved: solved
    }
  end

  # Local, struct-free equivalent of Result.solved?/1 to avoid forcing
  # `:problem_id`/`:prover` keys when we only have a status string.
  defp result_solved?(status), do: Result.solved?(status)

  defp problem_union(left_index, right_index) do
    left_ids = left_index |> Map.keys() |> Enum.map(fn {pid, _} -> pid end) |> MapSet.new()
    right_ids = right_index |> Map.keys() |> Enum.map(fn {pid, _} -> pid end) |> MapSet.new()
    MapSet.union(left_ids, right_ids)
  end

  # --- per-problem diff ---

  defp build_problem_diff(problem_id, left_index, right_index, our_prover) do
    left = Map.get(left_index, {problem_id, our_prover})
    right = Map.get(right_index, {problem_id, our_prover})

    %{
      problem_id: problem_id,
      prover: our_prover,
      left_status: left && Map.get(left, :szs_status),
      right_status: right && Map.get(right, :szs_status),
      left_solved: left && Map.get(left, :solved),
      right_solved: right && Map.get(right, :solved),
      change: classify_change(left, right)
    }
  end

  defp classify_change(nil, nil), do: :unchanged
  defp classify_change(%{solved: false}, %{solved: true}), do: :new_solve
  defp classify_change(%{solved: true}, %{solved: false}), do: :regression
  defp classify_change(nil, %{solved: true}), do: :new_solve
  defp classify_change(%{solved: true}, nil), do: :regression
  defp classify_change(%{szs_status: l}, %{szs_status: r}) when l == r, do: :unchanged
  defp classify_change(%{szs_status: _}, %{szs_status: _}), do: :status_change
  defp classify_change(_, _), do: :unchanged

  # --- per-prover deltas ---

  defp solve_deltas(left_index, right_index) do
    left_provers =
      left_index |> Map.keys() |> Enum.map(fn {_pid, prover} -> prover end) |> MapSet.new()

    right_provers =
      right_index |> Map.keys() |> Enum.map(fn {_pid, prover} -> prover end) |> MapSet.new()

    provers = MapSet.union(left_provers, right_provers)

    provers
    |> Enum.sort_by(&Atom.to_string/1)
    |> Enum.map(fn prover ->
      %{
        prover: prover,
        left_solved: count_solved(left_index, prover),
        right_solved: count_solved(right_index, prover)
      }
    end)
  end

  defp count_solved(index, prover) do
    index
    |> Enum.count(fn
      {{_pid, ^prover}, %{solved: true}} -> true
      _ -> false
    end)
  end

  defp run_id_from_results([first | _]) do
    Map.get(first, :run_id) || Map.get(first, "run_id")
  end

  defp run_id_from_results(_), do: nil

  defp blank_to_message("", message), do: message
  defp blank_to_message(value, _message) when is_binary(value), do: value
end
