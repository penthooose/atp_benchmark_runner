defmodule AtpBenchmarkRunner.Workflow do
  @moduledoc """
  High-level host workflows for completed benchmark runs.

  These functions keep Livebook cells and optional schedulers small: once SLURM
  jobs have finished, one call can collect cluster files, parse standardized SZS
  output, persist JSON artifacts, populate the local lightweight DB, and build a
  report for display or notification.
  """

  alias AtpBenchmarkRunner.{Notification, Report, Run, Store}
  alias AtpBenchmarkRunner.HPC.Results

  @doc """
  Collects remote results, stores artifacts, writes local DB records, and builds a report.

  Options are passed through to result collection and storage. The local DB is
  enabled by default because this workflow is intended for reproducible review;
  pass `db?: false` to only write JSON artifacts.
  """
  @spec collect_store_report!(HpcConnect.Session.t(), Run.t(), keyword()) :: map()
  def collect_store_report!(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    opts = Keyword.put_new(opts, :db?, true)
    results = Results.collect(session, run, opts)
    report = Report.summarize(results, run, opts)

    paths = %{
      run: maybe_save_run!(run, opts),
      results: Store.save_results!(run, results, opts),
      report: Store.save_report!(run, report, opts)
    }

    notification = maybe_notify(report, run, opts)

    %{
      run: run,
      results: results,
      report: report,
      paths: paths,
      db_path: if(Keyword.get(opts, :db?, true), do: Store.LocalDb.path(opts)),
      notification: notification
    }
  end

  @doc """
  Runs `collect_store_report!/3` and immediately renders the report panel.
  """
  @spec collect_store_report_panel!(HpcConnect.Session.t(), Run.t(), keyword()) :: map() | term()
  def collect_store_report_panel!(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    workflow = collect_store_report!(session, run, opts)
    AtpBenchmarkRunner.GUI.Report.panel(workflow.report, run, opts)
  end

  defp maybe_save_run!(run, opts) do
    if Keyword.get(opts, :save_run?, true), do: Store.save_run!(run, opts)
  end

  defp maybe_notify(report, run, opts) do
    cond do
      Keyword.get(opts, :notify_webhook?, false) ->
        Notification.send_webhook(report, run, opts)

      Keyword.get(opts, :write_email_summary?, false) ->
        {:ok, Notification.write_email_summary!(report, run, opts)}

      true ->
        :skipped
    end
  end
end
