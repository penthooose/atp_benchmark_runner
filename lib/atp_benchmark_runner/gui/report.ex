defmodule AtpBenchmarkRunner.GUI.Report do
  @moduledoc """
  Livebook/Kino rendering helpers for benchmark reports.
  """

  alias AtpBenchmarkRunner.{Compare, Report, Run}

  @doc """
  Renders a report as Kino markdown/tables.

  Pass `:artifact_paths` (map with `:run`, `:results`, `:report` keys)
  to show on-disk source artifact paths.
  """
  @spec panel([AtpBenchmarkRunner.Result.t() | map()] | map(), Run.t() | nil, keyword()) ::
          map() | term()
  def panel(results_or_report, run \\ nil, opts \\ []) do
    report = normalize_report(results_or_report, run, opts)
    artifact_paths = Keyword.get(opts, :artifact_paths)

    if available?() do
      render_report(report, artifact_paths)
    else
      %{kino?: false, report: report, artifact_paths: artifact_paths}
    end
  end

  @doc """
  Renders a longitudinal diff between two result lists as Kino tables.
  """
  @spec diff_panel(
          [AtpBenchmarkRunner.Result.t() | map()],
          [AtpBenchmarkRunner.Result.t() | map()],
          keyword()
        ) ::
          map() | term()
  def diff_panel(left_results, right_results, opts \\ []) do
    diff = Compare.diff(left_results, right_results, opts)

    if available?() do
      render_diff(diff)
    else
      %{kino?: false, diff: diff, markdown: Compare.markdown(diff)}
    end
  end

  defp render_diff(diff) do
    kino_render(kino_markdown(Compare.markdown(diff)))
    kino_render(kino_table(diff.per_prover_solve_deltas))
    maybe_render_table(diff.new_solves)
    maybe_render_table(diff.regressions)
    %{kino?: true, diff: diff}
  rescue
    e -> %{kino?: false, error: Exception.message(e), diff: diff}
  end

  @doc """
  Returns true when Kino rendering modules are available.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Kino) and Code.ensure_loaded?(Kino.DataTable)

  defp normalize_report(%{totals: _} = report, _run, _opts), do: report

  defp normalize_report(results, run, opts) when is_list(results),
    do: Report.summarize(results, run, opts)

  defp render_report(report, artifact_paths) do
    kino_render(kino_table(metadata_rows(report)))
    kino_render(kino_markdown(report.markdown))
    kino_render(kino_table(report.by_prover))
    maybe_render_table(Map.get(report, :result_rows, []))
    kino_render(kino_table(report.by_problem))
    kino_render(kino_table(flatten_rating_buckets(report.by_rating_bucket)))
    maybe_render_artifact_paths(artifact_paths)

    %{kino?: true, report: report, artifact_paths: artifact_paths}
  rescue
    e -> %{kino?: false, error: Exception.message(e), report: report}
  end

  defp flatten_rating_buckets(rows) do
    Enum.flat_map(rows, fn row ->
      Enum.map(row.buckets, fn bucket ->
        Map.merge(bucket, %{prover: row.prover})
      end)
    end)
  end

  defp metadata_rows(report) do
    [
      %{
        run_id: Map.get(report, :run_id),
        generated_at: Map.get(report, :generated_at),
        result_count: get_in(report, [:totals, :total_results]),
        solved_results: get_in(report, [:totals, :solved_results])
      }
    ]
  end

  defp maybe_render_table([]), do: :ok
  defp maybe_render_table(rows), do: kino_render(kino_table(rows))

  defp maybe_render_artifact_paths(nil), do: :ok
  defp maybe_render_artifact_paths(paths) when paths == %{}, do: :ok

  defp maybe_render_artifact_paths(paths) when is_map(paths) do
    kino_render(kino_markdown(artifact_markdown(paths)))
  end

  defp artifact_markdown(paths) do
    lines =
      [:run, :results, :report, :db_path, :notification]
      |> Enum.flat_map(fn key ->
        case Map.get(paths, key) || Map.get(paths, Atom.to_string(key)) do
          nil -> []
          value -> ["- `#{key}`: `#{value}`"]
        end
      end)

    """
    ### Source artifacts

    #{if lines == [], do: "No artifact paths supplied.", else: Enum.join(lines, "\n")}
    """
  end

  defp kino_markdown(markdown), do: apply(Module.concat(Kino, Markdown), :new, [markdown])
  defp kino_table(rows), do: apply(Module.concat(Kino, DataTable), :new, [rows])
  defp kino_render(term), do: apply(Kino, :render, [term])
end
