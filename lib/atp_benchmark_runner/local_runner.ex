defmodule AtpBenchmarkRunner.LocalRunner do
  @moduledoc """
  Runs ATP provers locally (not on HPC/SLURM) and collects results.

  This module provides a sequential execution path for local benchmarks, useful
  for smoke-testing, debugging, and running small problem sets without HPC
  cluster access. Each prover is invoked as a child process via `System.cmd/3`.

  ## Detection

  Use `detect_available/0` to see which provers are actually runnable on this machine:

      AtpBenchmarkRunner.LocalRunner.detect_available()
      # => %{tableaux: :escript, docker: false, on_path: []}

  ## Basic usage

      provers = [:tableaux]
      problems = AtpBenchmarkRunner.install_tptp_examples!()

      results = AtpBenchmarkRunner.LocalRunner.run_benchmark(provers, problems,
        timeout_seconds: 30
      )
  """

  alias AtpBenchmarkRunner.{Problem, Prover, Result}

  @doc """
  Detects which prover execution methods are available on this machine.

  Returns a map with:
  - `:tableaux` — `:escript`, `:mix`, or `:none`
  - `:docker` — `boolean()` whether Docker CLI responds
  - `:escript` — `boolean()` whether `escript` command is available
  - `:on_path` — list of prover atoms whose native binaries are on PATH
  - `:docker_images` — map of prover atom → `:available` | `:needs_pull` | `:needs_build` | `:unavailable`
  """
  @spec detect_available() :: map()
  def detect_available do
    docker_images =
      if detect_docker_available() do
        check_docker_images()
      else
        %{}
      end

    %{
      tableaux: detect_tableaux_available(),
      docker: detect_docker_available(),
      docker_images: docker_images,
      escript: detect_escript_available(),
      on_path: detect_provers_on_path()
    }
  end

  @doc """
  Returns the image status for a single prover as seen by Docker.
  Returns `:available`, `:needs_pull`, `:needs_build`, or `:unavailable`.
  """
  @spec docker_image_status(Prover.t() | atom() | binary()) :: atom()
  def docker_image_status(prover) do
    prover = normalize_prover(prover)
    container = prover_metadata(prover.name) |> Map.get(:container)

    case container do
      nil ->
        :unavailable

      %{docker_image: nil} ->
        :unavailable

      %{docker_image: img} ->
        case run_cmd("docker", ["images", "-q", img], []) do
          {output, 0} ->
            if String.trim(output) == "" do
              if container.dockerfile_path do
                :needs_build
              else
                :needs_pull
              end
            else
              :available
            end

          _ ->
            :needs_pull
        end
    end
  end

  @doc """
  Ensures the Docker image for a prover is available locally.
  Pulls from Docker Hub for official images, or builds from Dockerfile for custom ones.
  """
  @spec ensure_docker_image!(Prover.t() | atom() | binary(), keyword()) :: :ok
  def ensure_docker_image!(prover, opts \\ []) do
    prover = normalize_prover(prover)
    container = prover_metadata(prover.name) |> Map.get(:container)
    img = container && container.docker_image

    cond do
      is_nil(container) or is_nil(img) ->
        raise ArgumentError, "No Docker image defined for prover #{prover.name}"

      docker_image_status(prover) == :available ->
        :ok

      container.dockerfile_path ->
        build_docker_image!(prover, container, opts)

      true ->
        pull_docker_image!(img)
    end
  end

  @doc """
  Pulls a Docker image from a registry.
  """
  @spec pull_docker_image!(binary()) :: :ok
  def pull_docker_image!(image) do
    IO.puts("Pulling Docker image: #{image}")
    {output, exit_code} = run_cmd("docker", ["pull", image], [])

    if exit_code != 0 do
      raise RuntimeError,
            "Failed to pull Docker image #{image}: #{String.slice(output, 0, 500)}"
    end

    :ok
  end

  @doc """
  Builds a Docker image for a prover from its Dockerfile.
  """
  @spec build_docker_image!(Prover.t() | atom() | binary(), map(), keyword()) :: :ok
  def build_docker_image!(_prover, container, opts \\ []) do
    dockerfile_path = container.dockerfile_path
    app_root = :code.priv_dir(:atp_benchmark_runner) |> to_string() |> Path.dirname()
    abs_path = Path.expand(dockerfile_path, app_root)
    build_dir = Path.dirname(abs_path)
    tag = container.docker_image

    IO.puts("Building Docker image: #{tag} from #{dockerfile_path}")

    {output, exit_code} =
      run_cmd("docker", ["build", "-t", tag, build_dir], Keyword.get(opts, :cmd_opts, []))

    if exit_code != 0 do
      raise RuntimeError,
            "Failed to build Docker image #{tag}: #{String.slice(output, 0, 500)}"
    end

    :ok
  end

  @doc """
  Runs all selected provers against all selected problems sequentially.

  Returns a flat list of `Result` structs, one per (prover, problem) pair.

  ## Execution Strategy

  By default (`execution_strategy: :sequential_containers`), the runner uses
  sequential container execution:

    * All problems run for prover A before switching to prover B
    * Each container/image is loaded once per prover, reducing overhead
    * This is optimal for local Docker execution

  ## Options

    * `:timeout_seconds` — per-problem wall time limit (default: 60)
    * `:include_raw_output` — include full stdout in results (default: false)
    * `:verbose` — print Docker CLI invocations (default: false)
    * `:auto_ensure_images` — automatically pull/build missing Docker images
      before running (default: false). When true, the build/pull output is
      printed to stdout so you can see progress during a benchmark run.
    * `:execution_strategy` — execution pattern: `:sequential_containers`
      (default) runs all problems for one prover before switching to the next

  ## Examples

      # Sequential container execution (default)
      results = LocalRunner.run_benchmark(provers, problems,
        timeout_seconds: 120,
        auto_ensure_images: true
      )

      # Explicit sequential strategy
      results = LocalRunner.run_benchmark(provers, problems,
        timeout_seconds: 120,
        execution_strategy: :sequential_containers
      )
  """
  @spec run_benchmark([Prover.t() | atom() | binary()], [Problem.t() | binary()], keyword()) ::
          [Result.t()]
  def run_benchmark(provers, problems, opts \\ []) do
    provers = normalize_provers(provers)
    problems = normalize_problems(problems)
    timeout_seconds = Keyword.get(opts, :timeout_seconds, 60)
    include_raw_output = Keyword.get(opts, :include_raw_output, false)
    verbose = Keyword.get(opts, :verbose, false)
    auto_ensure = Keyword.get(opts, :auto_ensure_images, false)
    execution_strategy = Keyword.get(opts, :execution_strategy, :sequential_containers)

    # Pre-ensure Docker images for all provers that need it
    if auto_ensure do
      Enum.each(provers, fn prover ->
        if prover.name != :tableaux do
          container = prover_metadata(prover.name) |> Map.get(:container)

          if container && container.docker_image do
            case docker_image_status(prover.name) do
              :needs_build ->
                IO.puts("🏗️  Auto-building Docker image for #{prover.name}...")
                ensure_docker_image!(prover.name)
                IO.puts("   ✅ Done")

              :needs_pull ->
                IO.puts("📥 Auto-pulling Docker image for #{prover.name}...")
                ensure_docker_image!(prover.name)
                IO.puts("   ✅ Done")

              _ ->
                :ok
            end
          end
        end
      end)
    end

    case execution_strategy do
      :sequential_containers ->
        # Run all problems for one prover before switching to next prover
        # This reduces container loading times since each container starts once
        Enum.flat_map(provers, fn prover ->
          Enum.map(problems, fn problem ->
            run_one(prover, problem, timeout_seconds, include_raw_output, verbose)
          end)
        end)

      _ ->
        raise ArgumentError,
              "Unknown execution strategy: #{inspect(execution_strategy)}. " <>
                "Expected :sequential_containers."
    end
  end

  @doc """
  Runs one prover against one problem and returns a single `Result`.
  """
  @spec run_single(Prover.t() | atom() | binary(), Problem.t() | binary(), keyword()) ::
          Result.t()
  def run_single(prover, problem, opts \\ []) do
    opts = if Keyword.keyword?(opts), do: opts, else: []
    prover_mod = normalize_prover(prover)
    problem_mod = normalize_problem(problem)
    timeout_seconds = Keyword.get(opts, :timeout_seconds, 60)
    include_raw_output = Keyword.get(opts, :include_raw_output, false)
    verbose = Keyword.get(opts, :verbose, false)
    run_one(prover_mod, problem_mod, timeout_seconds, include_raw_output, verbose)
  end

  @doc """
  Renders the shell command for a given prover and problem.

  Returns `{executable, args, extra_opts}` where `extra_opts` may include
  `:cd` for mix-based execution.
  """
  @spec local_command(Prover.t(), Problem.t(), keyword()) :: {binary(), [binary()], keyword()}
  def local_command(%Prover{} = prover, %Problem{} = problem, opts \\ []) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, 60)
    problem_path = problem.path || problem.name

    case prover.name do
      :tableaux ->
        local_tableaux_command(problem_path, timeout_seconds)

      _other ->
        command = Prover.render_command(prover, problem_path, timeout_seconds: timeout_seconds)

        if String.starts_with?(command, "apptainer ") do
          rest = String.replace_prefix(command, "apptainer exec", "") |> String.trim()
          [exe | rest_args] = String.split(rest, " ", trim: true)
          {exe, rest_args, []}
        else
          [exe | rest_args] = String.split(command, " ", trim: true)
          {exe, rest_args, []}
        end
    end
  end

  # --- Detection helpers ---

  @doc false
  def detect_tableaux_available do
    solver_root = tableaux_solver_root()
    escript = Path.join(solver_root, "simple_tableaux_solver")

    cond do
      File.exists?(escript) -> :escript
      File.exists?(Path.join(solver_root, "mix.exs")) -> :mix
      true -> :none
    end
  end

  @doc false
  def detect_docker_available do
    System.find_executable("docker") != nil
  end

  @doc false
  def detect_escript_available do
    System.find_executable("escript") != nil
  end

  @doc false
  def detect_provers_on_path do
    all = Prover.builtins()

    Enum.reduce(all, [], fn %Prover{name: name, command_template: tmpl}, acc ->
      exe =
        tmpl
        |> String.replace("apptainer exec ", "")
        |> String.split(" ", trim: true)
        |> List.first()

      if exe && System.find_executable(exe) do
        [name | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  @doc false
  def check_docker_images do
    all = Prover.builtins()

    Map.new(all, fn prover ->
      container = prover_metadata(prover.name) |> Map.get(:container)
      img = container && container.docker_image

      status =
        cond do
          is_nil(container) or is_nil(img) ->
            :unavailable

          true ->
            case run_cmd("docker", ["images", "-q", img], []) do
              {output, 0} ->
                if String.trim(output) == "" do
                  if container.dockerfile_path, do: :needs_build, else: :needs_pull
                else
                  :available
                end

              _ ->
                :needs_pull
            end
        end

      {prover.name, status}
    end)
  end

  # --- Prover execution ---

  defp run_one(
         %Prover{name: :tableaux} = prover,
         %Problem{} = problem,
         timeout_seconds,
         raw?,
         _verbose
       ) do
    problem_path = problem.path || problem.name
    problem_id = problem.id

    {cmd, cmd_args, cmd_opts} = local_tableaux_command(problem_path, timeout_seconds)
    wall_start = System.monotonic_time(:millisecond)
    result = run_cmd(cmd, cmd_args, cmd_opts)
    wall_end = System.monotonic_time(:millisecond)
    wall_time_ms = wall_end - wall_start
    {output, exit_status} = result

    szs_status = infer_tableaux_szs(output, exit_status)

    Result.from_output(prover.name, problem_id, output,
      prover: prover.name,
      problem_id: problem_id,
      problem_name: problem.name,
      szs_status: szs_status,
      exit_status: exit_status,
      wall_time_ms: wall_time_ms,
      raw_output: if(raw?, do: output, else: nil)
    )
  end

  defp run_one(%Prover{} = prover, %Problem{} = problem, timeout_seconds, raw?, verbose) do
    problem_path = problem.path || problem.name
    problem_id = problem.id

    case try_docker_or_native(prover, problem_path, timeout_seconds, verbose) do
      {:ok, output, exit_status, wall_time_ms} ->
        Result.from_output(prover.name, problem_id, output,
          prover: prover.name,
          problem_id: problem_id,
          problem_name: problem.name,
          exit_status: exit_status,
          wall_time_ms: wall_time_ms,
          raw_output: if(raw?, do: output, else: nil)
        )

      {:gaveup, reason} ->
        gave_up_output = "% SZS status GaveUp\n% #{reason}\n"

        Result.from_output(prover.name, problem_id, gave_up_output,
          prover: prover.name,
          problem_id: problem_id,
          problem_name: problem.name,
          exit_status: -1,
          wall_time_ms: 0,
          raw_output: if(raw?, do: gave_up_output, else: nil)
        )
    end
  end

  defp try_docker_or_native(prover, problem_path, timeout_seconds, verbose) do
    command = Prover.render_command(prover, problem_path, timeout_seconds: timeout_seconds)

    if String.starts_with?(command, "apptainer ") do
      # Try running via Docker as a fallback for containerized provers
      if detect_docker_available() do
        run_via_docker(prover, problem_path, command, timeout_seconds, verbose)
      else
        # Try native binary stripped of apptainer prefix
        run_native_stripped(command)
      end
    else
      # Plain CLI command
      [exe | args] = String.split(command, " ", trim: true)

      case System.find_executable(exe) do
        nil ->
          {:gaveup, "Executable '#{exe}' not found on PATH. Install it or use Docker."}

        _ ->
          wall_start = System.monotonic_time(:millisecond)
          {output, exit_code} = run_cmd(exe, args, [])
          wall_end = System.monotonic_time(:millisecond)
          {:ok, output, exit_code, wall_end - wall_start}
      end
    end
  end

  defp run_native_stripped(command) do
    rest = String.replace_prefix(command, "apptainer exec", "") |> String.trim()
    [exe | args] = String.split(rest, " ", trim: true)

    case System.find_executable(exe) do
      nil ->
        {:gaveup,
         "Executable '#{exe}' not found on PATH. Docker is not running either — provers require Apptainer, Docker, or native binaries."}

      _ ->
        wall_start = System.monotonic_time(:millisecond)
        {output, exit_code} = run_cmd(exe, args, [])
        wall_end = System.monotonic_time(:millisecond)
        {:ok, output, exit_code, wall_end - wall_start}
    end
  end

  defp run_via_docker(prover, problem_path, apptainer_command, timeout_seconds, verbose) do
    container = prover_metadata(prover.name) |> Map.get(:container)

    case container do
      nil ->
        {:gaveup, "No container metadata for prover '#{prover.name}'"}

      %{docker_image: nil} ->
        {:gaveup, "No Docker image defined for prover '#{prover.name}'"}

      %{docker_image: img} ->
        status = docker_image_status(prover.name)

        case status do
          :needs_pull ->
            {:gaveup,
             "Docker image '#{img}' not found locally. Run `AtpBenchmarkRunner.LocalRunner.pull_docker_image!(#{inspect(img)})` first."}

          :needs_build ->
            {:gaveup,
             "Docker image '#{img}' not built. Run `AtpBenchmarkRunner.LocalRunner.ensure_docker_image!(: #{prover.name})` to build it."}

          :unavailable ->
            {:gaveup, "Docker image not available for prover '#{prover.name}'"}

          :available ->
            run_docker_container(
              prover,
              problem_path,
              img,
              apptainer_command,
              timeout_seconds,
              verbose
            )
        end
    end
  end

  @doc false
  def docker_path(path) do
    # Docker Desktop on Windows needs Unix-style paths: C:\foo → /c/foo
    case :os.type() do
      {:win32, _} ->
        unix_path = String.replace(path, "\\", "/")

        case Regex.run(~r/^([A-Za-z]):(\/.*)$/, unix_path) do
          [_, drive, rest] -> "/#{String.downcase(drive)}#{rest}"
          _ -> unix_path
        end

      _ ->
        path
    end
  end

  defp run_docker_container(
         prover,
         problem_path,
         image,
         _rendered_command,
         timeout_seconds,
         verbose
       ) do
    problem_id = Path.rootname(problem_path) |> Path.basename()
    problem_basename = Path.basename(problem_path, ".p")

    # Special handling for CVC5: convert TPTP → SMT-LIB before running
    {mount_dir, mount_file} =
      if prover.name == :cvc5 do
        smt_content = AtpBenchmarkRunner.TPTPToSMT.convert_file!(problem_path)
        smt_dir = AtpBenchmarkRunner.Config.smt_tmp_dir()
        File.mkdir_p!(smt_dir)
        smt_name = "#{problem_basename}.smt2"
        File.write!(Path.join(smt_dir, smt_name), smt_content)
        {docker_path(smt_dir), smt_name}
      else
        dir = problem_path |> Path.dirname() |> Path.expand() |> docker_path()
        file = Path.basename(problem_path)
        {dir, file}
      end

    # Build Docker args from the prover's command template
    rest =
      prover.command_template
      |> String.replace_prefix("apptainer exec ", "")
      |> String.trim()
      |> String.split(" ", trim: true)
      |> Enum.drop(2)

    prover_args =
      Enum.map(rest, fn arg ->
        arg
        |> String.replace("{problem}", "/problems/#{mount_file}")
        |> String.replace("{timeout_seconds}", to_string(timeout_seconds))
        |> String.replace("{timeout_ms}", to_string(timeout_seconds * 1_000))
        |> String.replace("{sif_path}", "/dev/null")
      end)

    docker_args =
      ["run", "--rm", "-v", "#{mount_dir}:/problems:ro", image] ++ prover_args

    if verbose do
      IO.puts("")
      IO.puts("🐳 [#{problem_id}] docker #{Enum.join(docker_args, " ")}")
    end

    wall_start = System.monotonic_time(:millisecond)
    {output, exit_code} = run_cmd("docker", docker_args, [])
    wall_end = System.monotonic_time(:millisecond)

    # Wrap CVC5 output in SZS format for compatibility with result parsing
    output =
      if prover.name == :cvc5 do
        trimmed = String.trim(output)

        szs_status =
          case trimmed do
            "sat" -> "Satisfiable"
            "unsat" -> "Unsatisfiable"
            "unknown" -> "Unknown"
            _ -> nil
          end

        if szs_status do
          "% SZS status #{szs_status}\n"
        else
          output
        end
      else
        output
      end

    {:ok, output, exit_code, wall_end - wall_start}
  end

  # --- Command execution ---

  defp run_cmd(executable, args, extra_opts) do
    case System.find_executable(executable) do
      nil ->
        {"% SZS status GaveUp\n% LocalRunner: executable #{inspect(executable)} not found on PATH",
         -1}

      _exe_path ->
        cmd_opts = [into: "", stderr_to_stdout: true, parallelism: false] ++ extra_opts

        try do
          {output, exit_code} = System.cmd(executable, args, cmd_opts)
          {output, exit_code}
        rescue
          e in ErlangError ->
            {"% SZS status Error\n% LocalRunner: command failed: #{inspect(e)}\n", -2}

          e ->
            {"% SZS status Error\n% LocalRunner: unexpected error: #{inspect(e)}\n", -3}
        end
    end
  end

  # --- Tableaux solver specific ---

  defp local_tableaux_command(problem_path, _timeout_seconds) do
    solver_root = tableaux_solver_root()
    escript = Path.join(solver_root, "simple_tableaux_solver")

    cond do
      File.exists?(escript) and detect_escript_available() ->
        {"escript", [escript, "--tptp-file", problem_path, "--symbolic-only"], []}

      File.exists?(Path.join(solver_root, "mix.exs")) ->
        {"mix",
         [
           "run",
           "--no-start",
           Path.join(solver_root, "run.exs"),
           "--",
           "--tptp-file",
           problem_path,
           "--symbolic-only"
         ], [cd: solver_root]}

      true ->
        {"echo", ["tableaux solver not available"], []}
    end
  end

  defp tableaux_solver_root do
    __DIR__
    |> Path.dirname()
    |> Path.dirname()
    |> Path.dirname()
    |> Path.join(
      "../item_12_Integrating_external_solvers_into_Elixir_and_Livebook/simple_tableaux_solver"
    )
    |> Path.expand()
  end

  @doc false
  def infer_tableaux_szs(output, exit_status) do
    cond do
      # SZS status already in output
      status = Result.parse_szs_status(output) ->
        status

      # Timeout
      exit_status == 124 or exit_status == 137 or
        String.contains?(output, "Timeout") or String.contains?(output, "timeout") ->
        "Timeout"

      # Executable not found / GaveUp
      exit_status == -1 ->
        "GaveUp"

      # Tableaux solver "status: UNSAT" → Unsatisfiable
      String.contains?(output, "status: UNSAT") or
          String.contains?(output, "final_status: unsat") ->
        "Unsatisfiable"

      # Tableaux solver "status: SAT" → Satisfiable
      String.contains?(output, "status: SAT") or
          String.contains?(output, "final_status: sat") ->
        "Satisfiable"

      # Generic unsatisfiable text
      String.contains?(output, "unsatisfiable") or
          (String.contains?(output, "UNSAT") and not String.contains?(output, "SAT")) ->
        "Unsatisfiable"

      # Generic theorem text (must NOT match bare "true" — too many false positives)
      String.contains?(output, "theorem") or
        String.contains?(output, "Theorem") or
          String.contains?(output, "valid") ->
        "Theorem"

      # Generic satisfiable text
      String.contains?(output, "satisfiable") or
        String.contains?(output, "Satisfiable") or
          String.contains?(output, "SATISFIABLE") ->
        "Satisfiable"

      # Closed branch indicator (last resort)
      String.contains?(output, "closed") ->
        "Satisfiable"

      # Unknown
      true ->
        "GaveUp"
    end
  end

  # --- Helpers ---

  @doc false
  def normalize_provers(provers), do: Enum.map(provers, &normalize_prover/1)

  @doc false
  def normalize_prover(%Prover{} = prover), do: prover
  def normalize_prover(name) when is_atom(name) or is_binary(name), do: Prover.builtin!(name)

  @doc false
  def normalize_problems(problems) do
    Enum.map(problems, &normalize_problem/1)
  end

  @doc false
  def normalize_problem(%Problem{} = problem), do: problem
  def normalize_problem(path) when is_binary(path), do: Problem.from_path(path)

  @doc false
  def prover_metadata(name) do
    provider =
      AtpBenchmarkRunner.Provers.providers()
      |> Enum.find(&(&1.prover().name == name))

    if provider do
      %{prover: provider.prover(), container: provider.container()}
    end
  end
end
