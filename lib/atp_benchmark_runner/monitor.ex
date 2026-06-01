defmodule AtpBenchmarkRunner.Monitor do
  @moduledoc """
  Progress monitoring for submitted benchmark runs.
  """

  alias AtpBenchmarkRunner.{Run}
  alias AtpBenchmarkRunner.HPC.{JobScript, RemoteFiles}

  @terminal_states ~w(CD COMPLETED F FAILED CA CANCELLED TO TIMEOUT OOM OUT_OF_MEMORY)

  @doc """
  Polls SLURM and result directories for one run.
  """
  @spec poll(HpcConnect.Session.t(), Run.t(), keyword()) :: map()
  def poll(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    jobs = submitted_job_rows(session, run, opts)
    progress = progress(session, run, opts)
    stuck_jobs = stuck_jobs(jobs, opts)

    maybe_cancel_stuck(session, stuck_jobs, opts)

    %{
      run_id: run.id,
      status: overall_status(progress, jobs),
      jobs: jobs,
      progress: progress,
      stuck_jobs: stuck_jobs,
      polled_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  @doc """
  Parses compact `sacct -P` output for completed jobs.
  """
  @spec parse_sacct(binary()) :: [map()]
  def parse_sacct(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "JobID|"))
    |> Enum.map(fn line ->
      case String.split(line, "|", parts: 5) do
        [job_id, state, exit_code, elapsed, max_rss] ->
          %{
            job_id: job_id,
            state: state,
            exit_code: exit_code,
            elapsed: elapsed,
            max_rss: max_rss
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp submitted_job_rows(session, %Run{} = run, opts) do
    job_ids = submitted_job_ids(run)

    rows =
      session
      |> HpcConnect.list_jobs_summary(connect_opts: Keyword.get(opts, :connect_opts, []))
      |> Enum.filter(fn row -> MapSet.member?(job_ids, row.job_id) end)

    if rows == [] and MapSet.size(job_ids) > 0 do
      sacct_rows(session, job_ids, opts)
    else
      rows
    end
  end

  defp sacct_rows(session, job_ids, opts) do
    ids = job_ids |> MapSet.to_list() |> Enum.join(",")

    command =
      "sacct -n -P -j #{ids} --format=JobID,State,ExitCode,Elapsed,MaxRSS 2>/dev/null || true"

    session
    |> HpcConnect.connect!(command, Keyword.get(opts, :connect_opts, []))
    |> parse_sacct()
  end

  defp progress(session, %Run{} = run, opts) do
    paths = remote_paths(run, session, opts)
    total = length(run.problems)

    Enum.map(run.provers, fn prover ->
      name = Atom.to_string(prover.name)
      result_dir = posix_join(paths.results_dir, name)
      out_count = RemoteFiles.list(session, result_dir, "*.out", opts) |> length()
      meta_count = RemoteFiles.list(session, result_dir, "*.meta.json", opts) |> length()
      completed = max(out_count, meta_count)

      %{
        prover: prover.name,
        result_dir: result_dir,
        total: total,
        completed: completed,
        pending: max(total - completed, 0),
        completion_rate: ratio(completed, total),
        output_files: out_count,
        metadata_files: meta_count
      }
    end)
  end

  defp stuck_jobs(jobs, opts) do
    threshold_seconds = Keyword.get(opts, :stuck_after_seconds)

    if is_integer(threshold_seconds) and threshold_seconds > 0 do
      Enum.filter(jobs, fn row ->
        state = Map.get(row, :state) || Map.get(row, "state")
        elapsed = Map.get(row, :time) || Map.get(row, :elapsed) || Map.get(row, "time") || "0:00"

        state in ["R", "RUNNING", "PD", "PENDING"] and
          elapsed_seconds(elapsed) > threshold_seconds
      end)
    else
      []
    end
  end

  defp maybe_cancel_stuck(session, stuck_jobs, opts) do
    if Keyword.get(opts, :cancel_stuck?, false) do
      Enum.each(stuck_jobs, fn row ->
        job_id = Map.get(row, :job_id) || Map.get(row, "job_id")

        if job_id,
          do:
            HpcConnect.cancel_job(session, job_id,
              connect_opts: Keyword.get(opts, :connect_opts, [])
            )
      end)
    end
  end

  defp overall_status(progress, jobs) do
    cond do
      progress != [] and Enum.all?(progress, &(&1.pending == 0)) -> :completed
      Enum.any?(jobs, &(Map.get(&1, :state) in @terminal_states)) -> :partially_completed
      jobs != [] -> :running
      true -> :unknown
    end
  end

  defp submitted_job_ids(%Run{} = run) do
    run.submitted_jobs
    |> Map.values()
    |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp remote_paths(%Run{remote_root: root} = run, _session, _opts)
       when is_binary(root) and root != "" do
    JobScript.remote_paths(run, root)
  end

  defp remote_paths(%Run{} = run, session, opts) do
    root = Keyword.get(opts, :remote_root, posix_join(session.work_dir, "atp_benchmark_runner"))
    JobScript.remote_paths(run, root)
  end

  defp elapsed_seconds(value) do
    value
    |> to_string()
    |> String.split(["-", ":"])
    |> Enum.map(&String.to_integer/1)
    |> case do
      [days, hours, minutes, seconds] -> days * 86_400 + hours * 3_600 + minutes * 60 + seconds
      [hours, minutes, seconds] -> hours * 3_600 + minutes * 60 + seconds
      [minutes, seconds] -> minutes * 60 + seconds
      [seconds] -> seconds
    end
  rescue
    _ -> 0
  end

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, total), do: part / total

  defp posix_join(left, right),
    do: Enum.join([String.trim_trailing(left, "/"), String.trim_leading(right, "/")], "/")
end
