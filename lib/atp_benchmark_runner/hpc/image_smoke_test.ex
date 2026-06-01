defmodule AtpBenchmarkRunner.HPC.ImageSmokeTest do
  @moduledoc """
  Smoke validation for built prover Apptainer images.
  """

  alias AtpBenchmarkRunner.{Prover, Result, TPTP}
  alias AtpBenchmarkRunner.HPC.{Images, JobScript, RemoteFiles, Shell}

  @doc """
  Returns a dry-run smoke-test plan for selected provers.
  """
  @spec plan(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def plan(%HpcConnect.Session{} = session, provers, opts \\ []) when is_list(provers) do
    remote_dir = remote_dir(session, opts)
    examples = TPTP.bundled_examples()

    %{
      remote_dir: remote_dir,
      timeout_seconds: Keyword.get(opts, :timeout_seconds, 30),
      entries: Enum.map(provers, &plan_entry(session, &1, examples, remote_dir, opts))
    }
  end

  @doc """
  Uploads bundled smoke examples and runs each selected prover image once.
  """
  @spec validate!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: [map()]
  def validate!(%HpcConnect.Session{} = session, provers, opts \\ []) when is_list(provers) do
    remote_dir = remote_dir(session, opts)
    examples = upload_examples!(session, remote_dir, opts)

    Enum.map(provers, &validate_prover!(session, &1, examples, remote_dir, opts))
  end

  defp plan_entry(session, %Prover{} = prover, examples, remote_dir, opts) do
    problem = select_example(prover, examples)

    %{
      prover: prover.name,
      sif_path: Images.remote_sif_path(session, prover),
      problem: problem.name,
      remote_problem_path: remote_problem_path(remote_dir, problem),
      command: command(prover, session, remote_problem_path(remote_dir, problem), opts)
    }
  end

  defp validate_prover!(session, %Prover{} = prover, examples, remote_dir, opts) do
    problem = select_example(prover, examples)
    remote_problem = remote_problem_path(remote_dir, problem)
    out_file = posix_join(remote_dir, "#{Atom.to_string(prover.name)}_#{problem.name}.out")
    timeout_seconds = Keyword.get(opts, :timeout_seconds, 30)

    remote_command = """
    set +e
    export HPC_WORK_DIR=#{Shell.quote(session.work_dir)}
    export PROBLEM_PATH=#{Shell.quote(remote_problem)}
    export OUT_FILE=#{Shell.quote(out_file)}
    timeout --preserve-status #{timeout_seconds}s bash -lc #{Shell.quote(command(prover, session, remote_problem, opts))} > #{Shell.quote(out_file)} 2>&1
    STATUS=$?
    cat #{Shell.quote(out_file)}
    printf '\nATP_SMOKE_EXIT=%s\n' "$STATUS"
    exit 0
    """

    output = HpcConnect.connect!(session, remote_command, Keyword.get(opts, :connect_opts, []))
    exit_status = parse_smoke_exit(output)
    result = Result.from_output(prover.name, problem.id, output, exit_status: exit_status)

    %{
      prover: prover.name,
      problem_id: problem.id,
      ok?: exit_status == 0 or Result.solved?(result),
      exit_status: exit_status,
      szs_status: result.szs_status,
      output_path: out_file,
      output_preview: String.slice(output, 0, 2_000)
    }
  end

  defp upload_examples!(session, remote_dir, opts) do
    RemoteFiles.mkdir_p!(session, remote_dir, opts)

    TPTP.bundled_examples()
    |> Enum.map(fn problem ->
      remote_path = remote_problem_path(remote_dir, problem)
      content = File.read!(problem.path)
      RemoteFiles.write_text!(session, remote_path, content, opts)
      %{problem | path: remote_path, source: :remote}
    end)
  end

  defp select_example(%Prover{} = prover, examples) do
    logics = prover.metadata[:logics] || []

    Enum.find(examples, hd(examples), fn example ->
      is_nil(example.logic) or Enum.any?(logics, &String.contains?(&1, example.logic))
    end)
  end

  defp remote_problem_path(remote_dir, problem),
    do: posix_join(remote_dir, Path.basename(problem.path))

  defp command(%Prover{} = prover, session, problem_path, opts) do
    prover = %{prover | sif_path: Images.remote_sif_path(session, prover)}
    timeout = Keyword.get(opts, :timeout_seconds, 30)

    prover
    |> JobScript.runtime_command(timeout, opts)
    |> String.replace("\"$PROBLEM_PATH\"", Shell.quote(problem_path))
  end

  defp remote_dir(session, opts) do
    Keyword.get(
      opts,
      :remote_dir,
      posix_join([session.work_dir, "atp_benchmark_runner", "smoke"])
    )
  end

  defp parse_smoke_exit(output) do
    case Regex.run(~r/ATP_SMOKE_EXIT=(\d+)/, output, capture: :all_but_first) do
      [status] -> String.to_integer(status)
      _ -> nil
    end
  end

  defp posix_join(parts) when is_list(parts),
    do:
      Enum.join(Enum.map(parts, &String.trim(to_string(&1), "/")), "/")
      |> then(&if(String.starts_with?(to_string(hd(parts)), "/"), do: "/" <> &1, else: &1))

  defp posix_join(left, right), do: posix_join([left, right])
end
