defmodule AtpBenchmarkRunner.HPC.Results do
  @moduledoc """
  Collects remote benchmark result files and parses them into `Result` structs.
  """

  alias AtpBenchmarkRunner.{Result, Run, Store}
  alias AtpBenchmarkRunner.HPC.{JobScript, RemoteFiles}

  @doc """
  Collects all remote result metadata/output files for a run.
  """
  @spec collect(HpcConnect.Session.t(), Run.t(), keyword()) :: [Result.t()]
  def collect(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    paths = remote_paths(run, session, opts)
    collected_at = Keyword.get(opts, :collected_at, timestamp())

    opts =
      opts |> Keyword.put_new(:run_id, run.id) |> Keyword.put_new(:collected_at, collected_at)

    problem_names = Map.new(run.problems, &{&1.id, &1.name})

    run.provers
    |> Enum.flat_map(fn prover ->
      collect_for_prover(session, paths.results_dir, prover.name, problem_names, opts)
    end)
    |> Enum.sort_by(&{&1.problem_id, &1.prover})
  end

  @doc """
  Collects results and persists them in the local store.
  """
  @spec collect_and_store!(HpcConnect.Session.t(), Run.t(), keyword()) :: {binary(), [Result.t()]}
  def collect_and_store!(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    results = collect(session, run, opts)
    {Store.save_results!(run, results, opts), results}
  end

  defp collect_for_prover(session, results_dir, prover_name, problem_names, opts) do
    dir = posix_join(results_dir, Atom.to_string(prover_name))
    meta_files = RemoteFiles.list(session, dir, "*.meta.json", opts)

    if meta_files == [] do
      session
      |> RemoteFiles.list(dir, "*.out", opts)
      |> Enum.map(&result_from_output_file(session, prover_name, &1, problem_names, opts))
    else
      Enum.map(meta_files, &result_from_meta_file(session, prover_name, &1, problem_names, opts))
    end
  end

  defp result_from_meta_file(session, prover_name, meta_path, problem_names, opts) do
    meta = session |> RemoteFiles.read_text!(meta_path, opts) |> Jason.decode!()
    output_path = Map.fetch!(meta, "output_path")
    output = RemoteFiles.read_text!(session, output_path, opts)
    problem_id = Map.fetch!(meta, "problem_id")

    result_attrs = %{
      run_id: Keyword.get(opts, :run_id),
      collected_at: Keyword.get(opts, :collected_at),
      problem_id: problem_id,
      problem_name: Map.get(problem_names, problem_id),
      prover: Map.get(meta, "prover", Atom.to_string(prover_name)),
      exit_status: Map.get(meta, "exit_status"),
      wall_time_ms: Map.get(meta, "wall_time_ms"),
      memory_kb: Map.get(meta, "memory_kb"),
      output_path: output_path,
      raw_output: maybe_raw_output(output, opts),
      metadata: %{
        remote_meta_path: meta_path,
        remote_resource_path: Map.get(meta, "resource_path")
      }
    }

    Result.from_output(prover_name, result_attrs.problem_id, output, Map.to_list(result_attrs))
  end

  defp result_from_output_file(session, prover_name, output_path, problem_names, opts) do
    output = RemoteFiles.read_text!(session, output_path, opts)
    problem_id = output_path |> Path.basename() |> String.replace_suffix(".out", "")

    Result.from_output(prover_name, problem_id, output,
      run_id: Keyword.get(opts, :run_id),
      collected_at: Keyword.get(opts, :collected_at),
      problem_name: Map.get(problem_names, problem_id),
      output_path: output_path,
      raw_output: maybe_raw_output(output, opts),
      metadata: %{remote_output_path: output_path, missing_meta?: true}
    )
  end

  defp maybe_raw_output(output, opts) do
    if Keyword.get(opts, :include_raw_output, false), do: output, else: nil
  end

  defp remote_paths(%Run{remote_root: root} = run, _session, _opts)
       when is_binary(root) and root != "" do
    JobScript.remote_paths(run, root)
  end

  defp remote_paths(%Run{} = run, session, opts) do
    root = Keyword.get(opts, :remote_root, posix_join(session.work_dir, "atp_benchmark_runner"))
    JobScript.remote_paths(run, root)
  end

  defp posix_join(left, right),
    do: Enum.join([String.trim_trailing(left, "/"), String.trim_leading(right, "/")], "/")

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
