defmodule AtpBenchmarkRunner.Workflow do
  @moduledoc """
  High-level host workflows for completed benchmark runs.

  These functions keep Livebook cells and optional schedulers small: once SLURM
  jobs have finished, one call can collect cluster files, parse standardized SZS
  output, persist JSON artifacts, populate the local lightweight DB, and build a
  report for display or notification.
  """

  alias AtpBenchmarkRunner.{Notification, Prover, Report, Run, Store, TPTP}
  alias AtpBenchmarkRunner.HPC.{Results, Submitter, TPTPSync}

  @doc """
  Collects remote results, stores artifacts, writes local DB, builds a report.

  Pass `db?: false` to skip the local DB and only write JSON artifacts.
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
    artifact_paths = build_artifact_paths(workflow, opts)

    AtpBenchmarkRunner.GUI.Report.panel(
      workflow.report,
      run,
      Keyword.put(opts, :artifact_paths, artifact_paths)
    )
  end

  @doc """
  One-shot nightly orchestration without Oban.

  Loads problems, syncs to cluster, builds a Run manifest, submits (or dry-runs),
  and persists job IDs. Does **not** poll or collect results — call
  `collect_store_report!/3` separately after jobs finish.

  Returns `%{run, submitted_jobs, dry_run?, plan}`.
  """
  @spec orchestrate_nightly(HpcConnect.Session.t(), keyword()) :: map()
  def orchestrate_nightly(%HpcConnect.Session{} = session, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    cluster = Keyword.get(opts, :cluster, session.cluster)
    partition = Keyword.get(opts, :partition)
    walltime = Keyword.get(opts, :walltime, "02:00:00")
    problem_timeout_seconds = Keyword.get(opts, :problem_timeout_seconds, 60)
    max_parallel_jobs = Keyword.get(opts, :max_parallel_jobs, 16)
    remote_root = Keyword.get(opts, :remote_root)

    prover_names = Keyword.get(opts, :provers, [:tableaux, :vampire, :eprover, :cvc5])
    provers = Enum.map(prover_names, &Prover.builtin!/1)

    problem_filter = Keyword.get(opts, :problem_filter, [])
    problems = build_nightly_problems(problem_filter)

    remote_problems =
      if problems == [] do
        []
      else
        TPTPSync.sync_problem_set!(session, problems, opts)
      end

    run =
      Run.new(
        title: Keyword.get(opts, :title, "ATP nightly benchmark"),
        cluster: cluster,
        partition: partition,
        walltime: walltime,
        problem_timeout_seconds: problem_timeout_seconds,
        max_parallel_jobs: max_parallel_jobs,
        remote_root: remote_root,
        problems: remote_problems,
        provers: provers,
        metadata: %{
          created_from: :workflow_orchestrate_nightly,
          problem_filter: problem_filter,
          dry_run: dry_run?,
          queued_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }
      )

    cond do
      dry_run? ->
        plan = Submitter.plan(run, session, opts)
        Store.save_run!(run, opts)
        Store.append_event!(run.id, %{event: "nightly_dry_run", plan_keys: Map.keys(plan)}, opts)

        %{
          run: run,
          dry_run?: true,
          submitted_jobs: %{},
          plan: plan,
          results: []
        }

      true ->
        submitted = Submitter.submit_run(session, run, opts)
        Store.save_run!(submitted, opts)

        Store.append_event!(
          submitted.id,
          %{event: "nightly_submitted", jobs: submitted.submitted_jobs},
          opts
        )

        %{
          run: submitted,
          dry_run?: false,
          submitted_jobs: submitted.submitted_jobs,
          plan: nil,
          results: []
        }
    end
  end

  defp build_nightly_problems(filter) when is_list(filter) do
    Enum.flat_map(filter, fn
      nil ->
        []

      {root, opts} when is_binary(root) and is_list(opts) ->
        TPTP.load_problem_set([root_dir: root] ++ opts)

      root when is_binary(root) ->
        TPTP.load_problem_set(root_dir: root)

      %AtpBenchmarkRunner.Problem{} = problem ->
        [problem]

      other ->
        raise ArgumentError, "unsupported problem_filter entry: #{inspect(other)}"
    end)
  end

  defp build_artifact_paths(workflow, _opts) do
    paths = Map.get(workflow, :paths) || %{}

    artifact_paths = %{
      run: paths[:run],
      results: paths[:results],
      report: paths[:report],
      db_path: Map.get(workflow, :db_path),
      notification: summarize_notification(Map.get(workflow, :notification))
    }

    if Enum.all?(artifact_paths, fn {_k, v} -> is_nil(v) end),
      do: nil,
      else: artifact_paths
  end

  defp summarize_notification(:skipped), do: nil
  defp summarize_notification({:ok, %{} = value}), do: "webhook ok (#{value.status})"
  defp summarize_notification({:ok, path}) when is_binary(path), do: path
  defp summarize_notification({:error, reason}), do: "notification error: #{inspect(reason)}"
  defp summarize_notification(other), do: inspect(other)

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
