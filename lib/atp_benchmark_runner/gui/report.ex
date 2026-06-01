defmodule AtpBenchmarkRunner.GUI.Report do
  @moduledoc """
  Livebook/Kino rendering helpers for benchmark reports.
  """

  alias AtpBenchmarkRunner.{Report, Run}

  @doc """
  Renders a report as Kino markdown/tables when available.
  """
  @spec panel([AtpBenchmarkRunner.Result.t() | map()] | map(), Run.t() | nil, keyword()) ::
          map() | term()
  def panel(results_or_report, run \\ nil, opts \\ []) do
    report = normalize_report(results_or_report, run, opts)

    if available?() do
      render_report(report)
    else
      %{kino?: false, report: report}
    end
  end

  @doc """
  Returns true when Kino rendering modules are available.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Kino) and Code.ensure_loaded?(Kino.DataTable)

  defp normalize_report(%{totals: _} = report, _run, _opts), do: report

  defp normalize_report(results, run, opts) when is_list(results),
    do: Report.summarize(results, run, opts)

  defp render_report(report) do
    kino_render(kino_table(metadata_rows(report)))
    kino_render(kino_markdown(report.markdown))
    kino_render(kino_table(report.by_prover))
    maybe_render_table(Map.get(report, :result_rows, []))
    kino_render(kino_table(report.by_problem))
    kino_render(kino_table(flatten_rating_buckets(report.by_rating_bucket)))

    %{kino?: true, report: report}
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

  defp kino_markdown(markdown), do: apply(Module.concat(Kino, Markdown), :new, [markdown])
  defp kino_table(rows), do: apply(Module.concat(Kino, DataTable), :new, [rows])
  defp kino_render(term), do: apply(Kino, :render, [term])
end
