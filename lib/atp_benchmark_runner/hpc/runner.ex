defmodule AtpBenchmarkRunner.HPC.Runner do
  @moduledoc """
  Runs benchmarks on HPC clusters via `hpc_connect`.

  Modes: `:single_node` (default, all provers on one node) or `:multi_node`.

      session = HpcConnect.Session.local()
      AtpBenchmarkRunner.HPC.Runner.bootstrap(session, provers, problems,
        mode: :hpc, hpc_mode: :single_node
      )
  """

  alias AtpBenchmarkRunner.{Input, Problem, Prover, Run, Store}

  alias AtpBenchmarkRunner.HPC.{
    Config,
    Images,
    JobScript,
    RemoteFiles,
    Results,
    Shell,
    Submitter,
    TPTPSync
  }

  @doc """
  Bootstrap function for HPC execution.

  Dispatches to the appropriate execution strategy based on `:hpc_mode`.

  ## Options

    * `:hpc_mode` - Execution mode: `:single_node` or `:multi_node` (default: `:single_node`)
    * `:timeout_seconds` - Per-problem wall time limit (default: 60)
    * `:partition` - SLURM partition to use (default: from session config)
    * `:time` - Wall time limit per job (default: "01:00:00")
    * `:include_raw_output` - Include full stdout in results (default: false)

  ## Returns

  A map with:

    * `:results` - List of `Result` structs
    * `:job_ids` - Map of prover to SLURM job ID
    * `:run` - The `Run` manifest
  """
  @spec bootstrap(
          HpcConnect.Session.t(),
          [Prover.t() | atom() | binary()],
          [Problem.t() | binary()],
          keyword()
        ) :: map()
  def bootstrap(session, provers, problems, opts \\ []) do
    run =
      AtpBenchmarkRunner.bootstrap(session, provers, problems, Keyword.put(opts, :mode, :hpc))

    run(run, session, opts)
  end

  @doc """
  Executes an existing run plan on the cluster and waits for completion.
  """
  @spec run(Run.t(), HpcConnect.Session.t(), keyword()) :: map()
  def run(%Run{} = run, %HpcConnect.Session{} = session, opts \\ []) do
    resolved_opts =
      run.metadata
      |> Map.get(:hpc, %{})
      |> Map.to_list()
      |> Keyword.merge(opts)

    hpc = Config.resolve(session, Keyword.put(resolved_opts, :prover_count, length(run.provers)))

    if session.extended_debug do
      IO.puts(
        "[hpc-ext-debug] #{stamp()} run #{run.id}: mode=#{hpc.hpc_mode} " <>
          "provers=#{length(run.provers)} problems=#{length(run.problems)} partition=#{hpc.partition}"
      )
    end

    # Persist the plan immediately so the run_id is discoverable in the store
    # even if a later step (sync/submit) fails. On success the manifest is
    # re-persisted below with :submitted status and job ids.
    case persist_run_manifest(run) do
      nil -> :ok
      path -> IO.puts("[runner] Run #{run.id} starting; manifest: #{path}")
    end

    remote_run =
      run
      |> sync_problems(session, hpc)
      |> Map.put(:cluster, hpc.cluster)
      |> Map.put(:partition, hpc.partition)
      |> Map.put(:walltime, hpc.walltime)
      |> Map.put(:remote_root, hpc.remote_root)
      |> Map.put(:max_parallel_jobs, hpc.max_parallel_jobs)

    case hpc.hpc_mode do
      :single_node -> run_single_node(session, remote_run, hpc)
      :multi_node -> run_multi_node(session, remote_run, hpc)
    end
  end

  @doc """
  Single-node execution: All provers run on one compute node as a job array.

  Each prover runs sequentially on the same node, with one SLURM job array
  containing all prover/problem combinations.
  """
  @spec run_single_node(
          HpcConnect.Session.t(),
          Run.t(),
          map()
        ) :: map()
  def run_single_node(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    case hpc.single_node_strategy do
      :parallel_sifs ->
        do_run_single_node(session, run, hpc)

      :direct_provers ->
        do_run_single_node(session, run, hpc)

      :bundled_container ->
        raise ArgumentError,
              "single-node strategy :bundled_container is not implemented yet; use :direct_provers with single_node_mode :parallel or :sequential for now"
    end
  end

  @doc """
  Multi-node execution: Each prover runs on a separate compute node.

  Submits one SLURM job per prover, with each job running all problems
  for that prover (job array per prover).
  """
  @spec run_multi_node(
          HpcConnect.Session.t(),
          Run.t(),
          map()
        ) :: map()
  def run_multi_node(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    submitted_run =
      Submitter.submit_run(session, with_default_sif_paths(run, session),
        remote_root: hpc.remote_root,
        max_parallel_jobs: hpc.max_parallel_jobs,
        cpus_per_task: hpc.cpus_per_task,
        ntasks: hpc.ntasks,
        nodes: hpc.nodes,
        gres: hpc.gres,
        constraint: hpc.constraint,
        mem: hpc.mem,
        exclusive: hpc.exclusive,
        prepare_images: hpc.prepare_images,
        debug: hpc.debug
      )

    job_ids_str =
      submitted_run.submitted_jobs
      |> Map.values()
      |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
      |> Enum.join(", ")

    IO.puts("[runner] Jobs submitted; IDs: #{job_ids_str}")

    persist_run_manifest(submitted_run)
    wait_for_completion!(session, submitted_run, hpc)

    results =
      try do
        Results.collect(session, submitted_run,
          include_raw_output: hpc.include_raw_output,
          remote_root: hpc.remote_root,
          collect_retry_forever: true
        )
      rescue
        e ->
          IO.puts("[runner] Results.collect warning: #{Exception.message(e)}")
          []
      end

    # Auto-kill: explicitly cancel job arrays so SLURM releases resources
    # immediately, even for jobs that already reached a terminal state. Wrapped
    # in try/rescue so SSH disruption during cleanup never crashes results.
    try do
      Submitter.cancel_run(session, submitted_run)
    rescue
      e -> IO.puts("[runner] cancel_run warning: #{Exception.message(e)}")
    end

    %{
      results: results,
      job_ids: submitted_run.submitted_jobs,
      run: submitted_run
    }
  end

  defp do_run_single_node(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    run = with_default_sif_paths(run, session)
    paths = JobScript.remote_paths(run, hpc.remote_root)

    if session.extended_debug do
      IO.puts(
        "[hpc-ext-debug] #{stamp()} submit: run_dir=#{paths.run_dir} results_dir=#{paths.results_dir}"
      )
    end

    maybe_prepare_images!(session, run, hpc)

    mkdir_cmd =
      "mkdir -p " <>
        Enum.map_join([paths.run_dir, paths.logs_dir, paths.results_dir], " ", &Shell.quote/1)

    HpcConnect.connect!(session, mkdir_cmd)

    RemoteFiles.write_text!(session, paths.problem_list, JobScript.problem_list(run), mode: "644")

    RemoteFiles.write_text!(
      session,
      paths.single_node_tasks,
      JobScript.single_node_tasks(run),
      mode: "644",
      # Over the steady shell, deliver the tasks file as one command instead of
      # several rapid base64-chunk writes. The steady shell pipes via stdin with
      # no Windows process-spawn limit, and collapsing the write burst avoids
      # destabilising the Livebook runtime.
      single_command: session.steady_connection == true
    )

    HpcConnect.install_remote_scripts!(session)

    submitted =
      HpcConnect.start_app(session,
        app: "atp_benchmark_runner",
        args: [
          partition: hpc.partition,
          gpus: 0,
          walltime: hpc.walltime,
          cpus: hpc.cpus_per_task,
          ntasks: hpc.ntasks,
          nodes: hpc.nodes,
          constraint: hpc.constraint,
          mem: hpc.mem,
          exclusive: hpc.exclusive,
          tasks_file: paths.single_node_tasks,
          results_dir: paths.results_dir,
          timeout_seconds: run.problem_timeout_seconds,
          single_node_mode: hpc.single_node_mode,
          max_parallel: hpc.max_parallel_jobs,
          log_dir: paths.logs_dir,
          debug: hpc.debug
        ],
        # The benchmark job is a short-lived batch job, not a long-running app:
        # return immediately with the job_id (no allocation wait) so the
        # manifest is persisted right after `sbatch`. Even if the Livebook
        # runtime later dies during polling, the run stays recorded as
        # submitted and `collect_last_hpc_results!` can recover it. The actual
        # completion wait happens below via `wait_for_completion!`.
        wait_for_node: false
      )

    IO.puts("[runner] Job submitted; ID: #{submitted.job_id}")

    submitted_run =
      run
      |> Map.put(:remote_root, hpc.remote_root)
      |> Run.mark_submitted(%{
        single_node: %{
          job_id: submitted.job_id,
          logs_dir: submitted.logs_dir,
          launcher: "hpc_connect.start_app",
          app: "atp_benchmark_runner"
        }
      })

    persist_run_manifest(submitted_run)
    wait_for_completion!(session, submitted_run, hpc)

    results =
      try do
        Results.collect(session, submitted_run,
          include_raw_output: hpc.include_raw_output,
          remote_root: hpc.remote_root,
          collect_retry_forever: true
        )
      rescue
        e ->
          IO.puts("[runner] Results.collect warning: #{Exception.message(e)}")
          []
      end

    # Auto-kill: explicitly cancel the job so SLURM releases the node.
    try do
      Submitter.cancel_run(session, submitted_run)
    rescue
      e -> IO.puts("[runner] cancel_run warning: #{Exception.message(e)}")
    end

    %{
      results: results,
      job_ids: %{single_node: %{job_id: submitted.job_id, logs_dir: submitted.logs_dir}},
      run: submitted_run
    }
  end

  defp maybe_prepare_images!(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    case hpc.prepare_images do
      true ->
        Images.ensure_for_run!(session, run.provers,
          build: true,
          use_slurm: true,
          walltime: hpc.walltime,
          install_scripts: false
        )

      _ ->
        :ok
    end
  end

  # Persists the run manifest to the local store so the run_id stays discoverable
  # and results can be resumed later without re-running. Called at run start
  # (plan record) and right after a successful submission.
  #
  # Bounded and non-fatal: on this Windows + Livebook setup a write right after
  # submit can freeze the node, so it runs in a Task with a 15 s cap. If it does
  # not finish, we log and continue. The submitted status is a convenience;
  # results stay recoverable via `collect_hpc_results!` remote discovery.
  defp persist_run_manifest(%Run{} = run, opts \\ []) do
    task = Task.async(fn -> Store.save_run!(run, opts) end)

    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, path} ->
        path

      nil ->
        IO.puts(
          "[runner] ⚠ Could not persist run manifest #{run.id} within 15s; " <>
            "skipped (non-fatal, results still recoverable via §7b)"
        )

        nil
    end
  rescue
    e ->
      IO.puts("[runner] Could not persist run manifest: #{Exception.message(e)}")
      nil
  end

  # ISO-8601 timestamp for extended-debug trace lines.
  defp stamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp sync_problems(%Run{} = run, %HpcConnect.Session{} = session, hpc) do
    if session.extended_debug do
      IO.puts(
        "[hpc-ext-debug] #{stamp()} sync: pre-converting inputs (cvc5→smt2, lash/shot_tx→thf)"
      )
    end

    # Pre-convert problems for provers whose `input` is not `:tptp`
    # (cvc5 to SMT, lash to THF). Must happen before syncing because the
    # converted files are uploaded to the vault alongside the originals.
    Enum.each(run.provers, fn prover ->
      if Input.needs_conversion?(prover) do
        Enum.each(run.problems, fn problem ->
          if local_file?(problem) and
               (String.ends_with?(problem.path, ".p") and
                  not String.ends_with?(problem.path, "_thf.p")) do
            # A conversion failure for one problem must not abort the whole
            # run, so skip it and let the problem surface as a visible GaveUp
            # instead of killing every prover.
            try do
              Input.convert_problem(prover, problem)
            rescue
              e ->
                IO.puts(
                  "[runner] ⚠ Skipping #{prover.name} input conversion for #{problem.name}: " <>
                    Exception.message(e)
                )
            end
          end
        end)
      end
    end)

    remote_problems =
      TPTPSync.sync_problem_set!(session, run.problems,
        remote_tptp_dir: hpc.remote_tptp_dir,
        extended_debug: session.extended_debug
      )

    if session.extended_debug do
      IO.puts(
        "[hpc-ext-debug] #{stamp()} sync: uploaded #{length(remote_problems)} problems to #{hpc.remote_tptp_dir}"
      )
    end

    %{run | problems: remote_problems}
  end

  defp local_file?(%Problem{source: :local}), do: true

  defp local_file?(%Problem{path: path}) when is_binary(path) do
    not String.starts_with?(path, "/")
  end

  defp local_file?(_), do: false

  defp wait_for_completion!(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    if hpc.wait_for_completion do
      deadline = System.monotonic_time(:millisecond) + hpc.max_wait_ms
      do_wait_for_completion(session, run, hpc, deadline)
    else
      :ok
    end
  end

  defp do_wait_for_completion(session, run, hpc, deadline, failed_count \\ 0, poll_count \\ 0) do
    job_ids =
      run.submitted_jobs
      |> Map.values()
      |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
      |> Enum.reject(&is_nil/1)

    states = batch_job_states(session, job_ids)

    cond do
      states == %{} ->
        IO.puts("[runner] No active jobs found; assuming completed")
        :ok

      states == :error ->
        backoff_ms = min((1000 * :math.pow(2, failed_count)) |> round(), 60_000)

        IO.puts(
          "[runner] SSH query failed, retrying in #{backoff_ms}ms (attempt ##{failed_count + 1})"
        )

        Process.sleep(backoff_ms)

        if System.monotonic_time(:millisecond) >= deadline do
          raise RuntimeError,
                "Timed out waiting for HPC benchmark jobs (SSH repeatedly failed)"
        end

        do_wait_for_completion(session, run, hpc, deadline, failed_count + 1, poll_count)

      Enum.all?(states, fn {_job_id, state} -> Config.terminal_state?(state) end) ->
        IO.puts("[runner] All jobs completed; states: #{inspect(states)}")
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise RuntimeError,
              "Timed out waiting for HPC benchmark jobs: #{inspect(states)}"

      true ->
        # Print progress every 5th poll
        if rem(poll_count, 5) == 0 do
          IO.puts(
            "[runner] Waiting for completion (poll ##{poll_count + 1}); states: #{inspect(states)}"
          )
        end

        Process.sleep(hpc.poll_interval_ms)
        do_wait_for_completion(session, run, hpc, deadline, 0, poll_count + 1)
    end
  end

  # Batch all job state queries into one SSH command instead of one per job.
  defp batch_job_states(_session, job_ids) when job_ids == [], do: %{}

  defp batch_job_states(session, job_ids) do
    ids = Enum.join(job_ids, ",")

    command =
      "sacct -j #{ids} --noheader --format=JobID,State --parsable2 2>/dev/null | " <>
        "sed 's/\\x1b\\[[0-9;]*m//g' | grep -v '^$' | grep -v 'WARNING' | grep -v 'Path' | grep -v '!!!' | " <>
        "awk -F'|' '$1 ~ /^[0-9]+$/ {print $1, $2}'"

    output =
      session
      |> HpcConnect.connect!(command)
      |> String.trim()

    if output == "" or output =~ ~r/connection refused/i or output =~ ~r/Connection closed/i or
         output =~ ~r/timed out/i do
      :error
    else
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ~r{\s+}, parts: 2) do
          [job_id, state] -> Map.put(acc, String.trim(job_id), String.trim(state))
          _ -> acc
        end
      end)
    end
  rescue
    _ -> :error
  end

  defp with_default_sif_paths(%Run{} = run, %HpcConnect.Session{} = session) do
    %{run | provers: Enum.map(run.provers, &with_default_sif_path(&1, session))}
  end

  defp with_default_sif_path(%Prover{sif_path: path} = prover, _session)
       when is_binary(path) and path != "",
       do: prover

  defp with_default_sif_path(%Prover{sif_name: name} = prover, %HpcConnect.Session{} = session)
       when is_binary(name) and name != "" do
    %{prover | sif_path: posix_join([session.work_dir, "singularity_images", "#{name}.sif"])}
  end

  defp with_default_sif_path(%Prover{} = prover, _session), do: prover

  defp posix_join(parts) do
    joined =
      parts
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim(&1, "/"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("/")

    if parts != [] and String.starts_with?(to_string(hd(parts)), "/"),
      do: "/" <> joined,
      else: joined
  end
end
