defmodule AtpBenchmarkRunner.HPC.Submitter do
  @moduledoc """
  `hpc_connect` adapter for submitting and managing benchmark runs on FAU HPC.

  The adapter intentionally depends on the public `HpcConnect` API and keeps all
  benchmark-specific SLURM script generation in `AtpBenchmarkRunner.HPC.JobScript`.
  """

  alias AtpBenchmarkRunner.{Prover, Run}
  alias AtpBenchmarkRunner.HPC.{Images, JobScript, Shell}

  @doc """
  Builds the remote submission plan without executing SSH commands.
  """
  @spec plan(Run.t(), HpcConnect.Session.t(), keyword()) :: map()
  def plan(%Run{} = run, %HpcConnect.Session{} = session, opts \\ []) do
    remote_root = remote_root(run, session, opts)
    run = %{run | remote_root: remote_root}
    paths = JobScript.remote_paths(run, remote_root)

    scripts =
      Map.new(run.provers, fn %Prover{} = prover ->
        script_path = remote_script_path(paths.scripts_dir, prover)
        prover = with_default_sif_path(prover, session)

        {prover.name,
         %{path: script_path, content: JobScript.build(run, prover, remote_root, opts)}}
      end)

    %{
      run: run,
      paths: paths,
      images: Images.plan(run.provers),
      problem_list: JobScript.problem_list(run),
      scripts: scripts
    }
  end

  @doc """
  Uploads run files and submits one SLURM job array per prover.

  Pass `dry_run: true` to return the generated plan without touching the cluster.
  """
  @spec submit_run(HpcConnect.Session.t(), Run.t(), keyword()) :: Run.t() | map()
  def submit_run(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    # Propagate debug flag for job script diagnostic injection
    opts = if Keyword.get(opts, :debug, false), do: Keyword.put(opts, :debug, true), else: opts
    plan = plan(run, session, opts)

    if Keyword.get(opts, :dry_run, false) do
      plan
    else
      maybe_prepare_images!(session, plan.run, opts)
      upload_plan!(session, plan, opts)

      submitted_jobs =
        Map.new(plan.scripts, fn {prover_name, script} ->
          output =
            HpcConnect.connect!(
              session,
              "sbatch --parsable #{Shell.quote(script.path)}",
              connect_opts(opts)
            )

          {prover_name, %{job_id: extract_job_id!(output), script_path: script.path}}
        end)

      plan.run
      |> Run.mark_submitted(submitted_jobs)
      |> tap(fn submitted ->
        AtpBenchmarkRunner.GUI.Cache.save_run!(submitted, opts)

        AtpBenchmarkRunner.GUI.Cache.record_event!(
          submitted,
          %{event: "submitted", jobs: submitted_jobs},
          opts
        )
      end)
    end
  end

  @doc """
  Returns current SLURM status rows for submitted jobs in the run.
  """
  @spec status(HpcConnect.Session.t(), Run.t(), keyword()) :: [map()]
  def status(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    job_ids =
      run.submitted_jobs
      |> Map.values()
      |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    session
    |> HpcConnect.list_jobs_summary(connect_opts: connect_opts(opts))
    |> Enum.filter(fn row -> MapSet.member?(job_ids, row.job_id) end)
  end

  @doc """
  Cancels all submitted SLURM jobs for the run.
  """
  @spec cancel_run(HpcConnect.Session.t(), Run.t(), keyword()) :: :ok
  def cancel_run(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    run.submitted_jobs
    |> Map.values()
    |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn job_id ->
      HpcConnect.cancel_job(session, job_id, connect_opts: connect_opts(opts))
    end)

    AtpBenchmarkRunner.GUI.Cache.record_event!(run, %{event: "cancelled"}, opts)
    :ok
  end

  defp upload_plan!(session, plan, opts) do
    paths = plan.paths

    mkdir_cmd =
      "mkdir -p " <>
        Enum.map_join(
          [paths.run_dir, paths.scripts_dir, paths.logs_dir, paths.results_dir],
          " ",
          &Shell.quote/1
        )

    HpcConnect.connect!(session, mkdir_cmd, connect_opts(opts))

    HpcConnect.connect!(
      session,
      JobScript.write_file_command(paths.problem_list, plan.problem_list, mode: "644"),
      connect_opts(opts)
    )

    Enum.each(plan.scripts, fn {_prover, script} ->
      HpcConnect.connect!(
        session,
        JobScript.write_file_command(script.path, script.content, mode: "755"),
        connect_opts(opts)
      )
    end)
  end

  defp maybe_prepare_images!(session, %Run{} = run, opts) do
    case Keyword.get(opts, :prepare_images, false) do
      true -> Images.ensure_for_run!(session, run.provers, Keyword.put(opts, :build, true))
      _ -> :ok
    end
  end

  defp remote_root(%Run{remote_root: root}, _session, _opts) when is_binary(root) and root != "",
    do: root

  defp remote_root(_run, %HpcConnect.Session{} = session, opts) do
    case Keyword.get(opts, :remote_root) do
      root when is_binary(root) and root != "" -> root
      _ -> posix_join(session.work_dir, "atp_benchmark_runner")
    end
  end

  defp remote_script_path(scripts_dir, %Prover{} = prover) do
    posix_join(scripts_dir, "#{Atom.to_string(prover.name)}.sbatch")
  end

  defp with_default_sif_path(%Prover{sif_path: path} = prover, _session)
       when is_binary(path) and path != "", do: prover

  defp with_default_sif_path(%Prover{sif_name: name} = prover, %HpcConnect.Session{} = session)
       when is_binary(name) and name != "" do
    %{prover | sif_path: posix_join([session.work_dir, "singularity_images", "#{name}.sif"])}
  end

  defp with_default_sif_path(%Prover{} = prover, _session), do: prover

  defp connect_opts(opts), do: Keyword.get(opts, :connect_opts, [])

  defp extract_job_id!(output) do
    output
    |> String.split(["\n", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.match?(&1, ~r/^\d+$/))
    |> case do
      nil -> raise RuntimeError, "sbatch returned no valid job id: #{inspect(output)}"
      job_id -> job_id
    end
  end

  defp posix_join(parts) when is_list(parts) do
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

  defp posix_join(left, right),
    do: posix_join([left, right])
end
