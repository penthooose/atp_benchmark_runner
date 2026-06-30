defmodule AtpBenchmarkRunner.HPC.Runner do
  @moduledoc """
  Runs benchmarks on HPC clusters via `hpc_connect`.

  Modes: `:single_node` (default, all provers on one node) or `:multi_node`.

      session = HpcConnect.Session.local()
      AtpBenchmarkRunner.HPC.Runner.bootstrap(session, provers, problems,
        mode: :hpc, hpc_mode: :single_node
      )
  """

  alias AtpBenchmarkRunner.{Problem, Prover, Run}

  alias AtpBenchmarkRunner.HPC.{
    Config,
    Images,
    JobScript,
    RemoteFiles,
    Results,
    Submitter,
    TPTPSync
  }

  @doc """
  Bootstrap function for HPC execution.

  Dispatches to the appropriate execution strategy based on `:hpc_mode`.

  ## Options

    * `:hpc_mode` — Execution mode: `:single_node` or `:multi_node` (default: `:single_node`)
    * `:timeout_seconds` — Per-problem wall time limit (default: 60)
    * `:partition` — SLURM partition to use (default: from session config)
    * `:time` — Wall time limit per job (default: "01:00:00")
    * `:include_raw_output` — Include full stdout in results (default: false)

  ## Returns

  A map with:

    * `:results` — List of `Result` structs
    * `:job_ids` — Map of prover → SLURM job ID
    * `:run` — The `Run` manifest
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
        prepare_images: hpc.prepare_images
      )

    wait_for_completion!(session, submitted_run, hpc)

    results =
      Results.collect(session, submitted_run,
        include_raw_output: hpc.include_raw_output,
        remote_root: hpc.remote_root
      )

    %{
      results: results,
      job_ids: submitted_run.submitted_jobs,
      run: submitted_run
    }
  end

  defp do_run_single_node(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    run = with_default_sif_paths(run, session)
    paths = JobScript.remote_paths(run, hpc.remote_root)

    maybe_prepare_images!(session, run, hpc)

    RemoteFiles.mkdir_p!(session, paths.run_dir)
    RemoteFiles.mkdir_p!(session, paths.logs_dir)
    RemoteFiles.mkdir_p!(session, paths.results_dir)

    RemoteFiles.write_text!(session, paths.problem_list, JobScript.problem_list(run), mode: "644")

    RemoteFiles.write_text!(
      session,
      paths.single_node_tasks,
      JobScript.single_node_tasks(run),
      mode: "644"
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
          log_dir: paths.logs_dir
        ]
      )

    submitted_run =
      run
      |> Run.mark_submitted(%{
        single_node: %{
          job_id: submitted.job_id,
          logs_dir: submitted.logs_dir,
          launcher: "hpc_connect.start_app",
          app: "atp_benchmark_runner"
        }
      })

    wait_for_completion!(session, submitted_run, hpc)

    results =
      Results.collect(session, submitted_run,
        include_raw_output: hpc.include_raw_output,
        remote_root: hpc.remote_root
      )

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

  defp sync_problems(%Run{} = run, %HpcConnect.Session{} = session, hpc) do
    remote_problems =
      TPTPSync.sync_problem_set!(session, run.problems, remote_tptp_dir: hpc.remote_tptp_dir)

    %{run | problems: remote_problems}
  end

  defp wait_for_completion!(%HpcConnect.Session{} = session, %Run{} = run, hpc) do
    if hpc.wait_for_completion do
      deadline = System.monotonic_time(:millisecond) + hpc.max_wait_ms
      do_wait_for_completion(session, run, hpc, deadline)
    else
      :ok
    end
  end

  defp do_wait_for_completion(session, run, hpc, deadline) do
    job_ids =
      run.submitted_jobs
      |> Map.values()
      |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
      |> Enum.reject(&is_nil/1)

    states = Map.new(job_ids, &{&1, job_state(session, &1)})

    cond do
      states == %{} ->
        :ok

      Enum.all?(states, fn {_job_id, state} -> Config.terminal_state?(state) end) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise RuntimeError,
              "Timed out waiting for HPC benchmark jobs: #{inspect(states)}"

      true ->
        Process.sleep(hpc.poll_interval_ms)
        do_wait_for_completion(session, run, hpc, deadline)
    end
  end

  defp job_state(%HpcConnect.Session{} = session, job_id) do
    command =
      "state=$(sacct -j #{job_id} --noheader --format=State --parsable2 2>/dev/null | " <>
        "sed 's/\\x1b\\[[0-9;]*m//g' | grep -v '^$' | grep -v 'WARNING' | grep -v 'Path' | grep -v '!!!' | head -1 || true); " <>
        "if [ -n \"$state\" ]; then printf '%s' \"$state\"; else squeue -j #{job_id} -h -o '%T' 2>/dev/null | head -1 || true; fi"

    session
    |> HpcConnect.connect!(command)
    |> String.trim()
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
