defmodule AtpBenchmarkRunner.MultiRun do
  @moduledoc """
  Cross-run comparison and statistics over all stored benchmark runs.

  Loads every `*.results.json` from the store directory, aggregates each
  (problem, prover) pair across runs, and renders:

    * a per-problem × prover **best-time matrix** (with solved status),
    * a per-problem × prover **time-range matrix** (min–max ms across runs),
    * a **prover ranking** by solved problems.

  By design the results stay in JSON files (no database yet — columns may still
  change during development). Ranking treats statuses such as `InputError`,
  `TypeError`, `UnsupportedLogic` and `Error` as *non-attempts* by default
  (the prover was not applicable to that problem), while `Timeout`/`GaveUp`
  always count as real attempts — see `exclude_statuses/1` and the
  `:exclude_statuses` option.

  ## Examples

      stats = AtpBenchmarkRunner.MultiRun.stats()
      AtpBenchmarkRunner.MultiRun.print(stats)
      AtpBenchmarkRunner.MultiRun.save!("C:/tmp/comparison.md", stats)

  Inside Livebook use `panel/2` to get a `Kino.Markdown` (falls back to a
  plain markdown string outside Livebook).
  """

  alias AtpBenchmarkRunner.{Result, Store}

  # Statuses that indicate the prover never made a real attempt (wrong input
  # dialect / logic the prover does not support), so they should not count as
  # attempted problems in the ranking. Timeouts are deliberately NOT excluded.
  @default_exclude_statuses ["InputError", "UnsupportedLogic", "TypeError", "Error"]

  @doc """
  Default statuses treated as "not a real attempt" in the ranking.
  """
  @spec default_exclude_statuses() :: [binary()]
  def default_exclude_statuses, do: @default_exclude_statuses

  @doc """
  Loads every stored result run (newest first), skipping empty/malformed files.

  Each entry is `%{run_id, path, saved_at, results}` where `results` is a list
  of `Result.t()`. The `:dir` option overrides the store directory.
  """
  @spec load_all_runs(keyword()) :: [map()]
  def load_all_runs(opts \\ []) do
    dir = Keyword.get(opts, :dir, Store.default_dir())

    dir
    |> Path.join("*.results.json")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.flat_map(fn path ->
      case load_run(path) do
        {:ok, run} -> [run]
        :error -> []
      end
    end)
  end

  @doc """
  Computes cross-run comparison statistics.

  `runs` may be `nil` (load all stored runs) or an explicit list of run maps as
  returned by `load_all_runs/1`.

  Options:

    * `:dir` — store directory to read when `runs` is `nil`
      (default: `Store.default_dir/0`)
    * `:exclude_statuses` — statuses treated as non-attempts in the ranking
      (default: `default_exclude_statuses/0`); timeouts are never excluded
    * `:only_common_problems` — when `true`, the ranking only counts problems
      that every prover in scope attempted, so provers are compared on the
      same problem set

  Returns a map with `:runs`, `:problems`, `:provers`, `:per_problem`,
  `:per_prover`, `:ranking`, `:exclude_statuses` and `:generated_at`.
  """
  @spec stats([map()] | nil, keyword()) :: map()
  def stats(runs, opts \\ []) do
    runs = normalize_runs(runs, opts)
    exclude = Keyword.get(opts, :exclude_statuses, @default_exclude_statuses)
    exclude_set = MapSet.new(exclude)

    records = Enum.flat_map(runs, &run_records/1)

    cell_map =
      records
      |> Enum.group_by(fn {{pid, prov}, _} -> {pid, prov} end, fn {_, rec} -> rec end)

    cells =
      Map.new(cell_map, fn {key, recs} -> {key, build_cell(recs, exclude_set)} end)

    problems = cells |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    provers = cells |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    per_prover =
      Enum.map(provers, fn prov ->
        prov_cells = Enum.filter(cells, fn {{_pid, p}, _} -> p == prov end)
        build_prover_summary(prov, prov_cells)
      end)
      |> Enum.sort_by(fn p -> {-p.solved, -p.solve_rate} end)

    ranking =
      if Keyword.get(opts, :only_common_problems, false) do
        # Common set = problems every prover in scope ran (has a result for),
        # so all provers are ranked on exactly the same problem set.
        common =
          Enum.filter(problems, fn pid ->
            Enum.all?(provers, fn prov -> Map.has_key?(cells, {pid, prov}) end)
          end)

        Enum.map(per_prover, fn p ->
          # Every prover has a cell for every common problem (by construction),
          # so `attempted` is the full shared set — even non-applicable statuses
          # (e.g. InputError) count here, keeping all provers on the same set.
          attempted = length(common)
          solved = Enum.count(common, &Map.get(p.by_problem, &1, false))
          rate = if attempted > 0, do: solved / attempted, else: 0.0

          %{p | attempted: attempted, solved: solved, solve_rate: rate}
        end)
      else
        per_prover
      end
      |> Enum.sort_by(fn p -> {-p.solved, -p.solve_rate} end)

    # Order matrix columns by ranking (best prover first).
    ordered_provers = Enum.map(ranking, & &1.prover)

    per_problem =
      Enum.map(problems, fn pid ->
        %{
          problem_id: pid,
          provers:
            Map.new(ordered_provers, fn prov ->
              {prov, Map.get(cells, {pid, prov}) || empty_cell()}
            end)
        }
      end)

    %{
      generated_at:
        Keyword.get(
          opts,
          :generated_at,
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        ),
      runs: Enum.map(runs, &run_summary/1),
      exclude_statuses: Enum.sort(exclude),
      problems: problems,
      provers: ordered_provers,
      per_problem: per_problem,
      per_prover: per_prover,
      ranking: ranking
    }
  end

  @doc """
  Renders cross-run comparison statistics as Markdown.
  """
  @spec markdown(map(), keyword()) :: binary()
  def markdown(stats, opts \\ []) when is_map(stats) do
    _ = opts

    runs_block =
      if stats.runs == [] do
        "  _(no runs found — nothing to compare)_"
      else
        stats.runs
        |> Enum.map_join("\n", fn r ->
          "  - `#{r.run_id}` — #{r.saved_at || "?"}, #{r.n_results} results" <>
            " (provers: #{Enum.join(r.provers, ", ")})"
        end)
      end

    [
      "# Cross-run benchmark comparison",
      "",
      "- Generated: `#{stats.generated_at}`",
      "- Runs compared: #{length(stats.runs)}",
      "- Statuses not counted as attempts: `#{Enum.join(stats.exclude_statuses, ", ")}`",
      "- Note: `Timeout`/`GaveUp` are real attempts and are never excluded.",
      "",
      "## Runs included",
      "",
      runs_block,
      "",
      "## Prover ranking (by solved problems)",
      "",
      "| Prover | Attempted | Solved | Rate | Best-time Σ (ms) | Min (ms) | Max (ms) | Avg (ms) |",
      "|--------|----------:|-------:|-----:|-----------------:|---------:|---------:|---------:|",
      Enum.map_join(stats.ranking, "\n", &rank_row/1),
      "",
      "## Per-problem × prover — best time & status",
      "",
      matrix_table(stats, &best_cell/1),
      "",
      "## Per-problem × prover — time range (min–max ms)",
      "",
      matrix_table(stats, &range_cell/1)
    ]
    |> Enum.join("\n")
  end

  @doc """
  Prints the cross-run comparison Markdown to stdout.
  """
  @spec print(map(), keyword()) :: :ok
  def print(stats, opts \\ []) when is_map(stats) do
    IO.puts(markdown(stats, opts))
    :ok
  end

  @doc """
  Writes the cross-run comparison Markdown to `path` and returns the path.
  """
  @spec save!(binary(), map(), keyword()) :: binary()
  def save!(path, stats, opts \\ []) when is_map(stats) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, markdown(stats, opts))
    path
  end

  @doc """
  Renders the comparison for the current environment.

  Returns a `Kino.Markdown` when the Kino application is running (Livebook),
  otherwise a plain markdown string.
  """
  @spec panel(map(), keyword()) :: term()
  def panel(stats, opts \\ []) when is_map(stats) do
    if kino_available?() do
      Kino.Markdown.new(markdown(stats, opts))
    else
      markdown(stats, opts)
    end
  end

  @doc """
  True when a native Kino Markdown renderer is available (i.e. inside Livebook).
  """
  @spec available?() :: boolean()
  def available?, do: kino_available?()

  # ── loading ──────────────────────────────────────────────────────────────

  defp load_run(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, json} <- Jason.decode(contents),
         %{"results" => results} when is_list(results) and results != [] <- json do
      run_id = json["run_id"] || Path.basename(path, ".results.json")

      parsed =
        Enum.flat_map(results, fn entry ->
          try do
            # Comparison statistics only need status/timing fields — drop the
            # (potentially huge) raw proof output to keep loading fast.
            [%{Result.from_map(entry) | raw_output: nil}]
          rescue
            _ -> []
          end
        end)

      if parsed == [] do
        :error
      else
        {:ok,
         %{
           run_id: run_id,
           path: path,
           saved_at: get_in(json, ["metadata", "saved_at"]),
           results: parsed
         }}
      end
    else
      _ -> :error
    end
  end

  defp normalize_runs(nil, opts), do: load_all_runs(opts)
  defp normalize_runs(runs, _opts) when is_list(runs), do: runs

  defp run_summary(run) do
    %{
      run_id: run.run_id,
      saved_at: run.saved_at,
      n_results: length(run.results),
      solved: Enum.count(run.results, &Result.solved?/1),
      provers:
        run.results
        |> Enum.map(& &1.prover)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp run_records(run) do
    Enum.map(run.results, fn r ->
      {{r.problem_id, r.prover},
       %{
         run_id: run.run_id,
         time_ms: r.wall_time_ms,
         status: r.szs_status || "Unknown",
         solved: Result.solved?(r)
       }}
    end)
  end

  # ── aggregation ──────────────────────────────────────────────────────────

  defp build_cell(records, exclude_set) do
    attempted = Enum.any?(records, &valid_attempt?(&1.status, exclude_set))
    solved = Enum.any?(records, & &1.solved)

    solve_times =
      records |> Enum.filter(& &1.solved) |> Enum.map(& &1.time_ms) |> Enum.reject(&is_nil/1)

    attempt_times = records |> Enum.map(& &1.time_ms) |> Enum.reject(&is_nil/1)

    # records are in newest-first run order (load_all_runs sorts desc)
    latest = List.first(records) || %{status: "Unknown"}

    %{
      attempted: attempted,
      solved: solved,
      status: latest.status,
      best_ms: Enum.min(solve_times, fn -> nil end),
      min_ms: Enum.min(attempt_times, fn -> nil end),
      max_ms: Enum.max(attempt_times, fn -> nil end),
      avg_ms: avg(solve_times),
      n_runs: length(records)
    }
  end

  defp empty_cell do
    %{
      attempted: false,
      solved: false,
      status: nil,
      best_ms: nil,
      min_ms: nil,
      max_ms: nil,
      avg_ms: nil,
      n_runs: 0
    }
  end

  defp build_prover_summary(prover, prov_cells) do
    attempted = Enum.count(prov_cells, fn {_, c} -> c.attempted end)
    solved = Enum.count(prov_cells, fn {_, c} -> c.solved end)
    rate = if attempted > 0, do: solved / attempted, else: 0.0

    best_times = prov_cells |> Enum.map(fn {_, c} -> c.best_ms end) |> Enum.reject(&is_nil/1)
    attempt_times = prov_cells |> Enum.map(fn {_, c} -> c.min_ms end) |> Enum.reject(&is_nil/1)

    %{
      prover: prover,
      attempted: attempted,
      solved: solved,
      solve_rate: rate,
      best_time_sum_ms: Enum.sum(best_times),
      min_time_ms: Enum.min(attempt_times, fn -> nil end),
      max_time_ms: Enum.max(attempt_times, fn -> nil end),
      avg_time_ms: avg(attempt_times),
      by_problem: Map.new(prov_cells, fn {{pid, _}, c} -> {pid, c.solved} end)
    }
  end

  defp valid_attempt?(status, exclude_set),
    do: not MapSet.member?(exclude_set, status)

  # ── rendering ────────────────────────────────────────────────────────────

  defp matrix_table(stats, cell_fun) do
    header =
      "| Problem | #{Enum.map_join(stats.provers, " | ", & &1)} |"

    sep =
      "|---------|#{Enum.map_join(stats.provers, "-|", fn _ -> "------" end)}-|"

    rows =
      Enum.map_join(stats.per_problem, "\n", fn row ->
        cells = Enum.map(stats.provers, fn prov -> cell_fun.(Map.get(row.provers, prov)) end)
        "| #{row.problem_id} | #{Enum.join(cells, " | ")} |"
      end)

    [header, sep, rows] |> Enum.join("\n")
  end

  defp best_cell(cell) do
    cond do
      cell.solved and cell.best_ms != nil -> "✅ #{cell.best_ms}ms"
      cell.solved -> "✅"
      cell.status in [nil, "Unknown"] -> "—"
      true -> "❌ #{cell.status}"
    end
  end

  defp range_cell(cell) do
    cond do
      cell.min_ms != nil and cell.max_ms != nil ->
        if cell.min_ms == cell.max_ms do
          "#{cell.min_ms}ms"
        else
          "#{cell.min_ms}–#{cell.max_ms}ms"
        end

      cell.min_ms != nil ->
        "#{cell.min_ms}ms"

      true ->
        "—"
    end
  end

  defp rank_row(p) do
    "| #{p.prover} | #{p.attempted} | #{p.solved} | #{Float.round(p.solve_rate * 100, 1)}% | " <>
      "#{p.best_time_sum_ms} | #{ms(p.min_time_ms)} | #{ms(p.max_time_ms)} | #{ms(p.avg_time_ms)} |"
  end

  defp ms(nil), do: "-"
  defp ms(n), do: "#{n}"

  defp avg([]), do: nil
  defp avg(list), do: Float.round(Enum.sum(list) / length(list), 1)

  defp kino_available? do
    Code.ensure_loaded?(Kino.Markdown) and
      List.keymember?(Application.started_applications(), :kino, 0)
  end
end
