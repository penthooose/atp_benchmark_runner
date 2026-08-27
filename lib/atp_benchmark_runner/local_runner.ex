defmodule AtpBenchmarkRunner.LocalRunner do
  @moduledoc """
  Runs ATP provers locally via `System.cmd/3`, no HPC/SLURM needed.

  Good for smoke-testing and debugging small problem sets.

      provers = [:tableaux]
      problems = AtpBenchmarkRunner.install_tptp_examples!()
      results = AtpBenchmarkRunner.LocalRunner.run_benchmark(provers, problems,
        timeout_seconds: 30
      )
  """

  alias AtpBenchmarkRunner.{Config, Input, Problem, Prover, Result}

  @doc """
  Returns a map of available execution methods on this machine.

  Keys: `:tableaux`, `:docker`, `:docker_images`, `:apptainer`,
  `:apptainer_images`, `:escript`, `:on_path`.
  """
  @spec detect_available() :: map()
  def detect_available do
    docker_images = if detect_docker_available(), do: check_docker_images(), else: %{}
    apptainer_images = if detect_apptainer_available(), do: check_apptainer_images(), else: %{}

    %{
      tableaux: detect_tableaux_available(),
      docker: detect_docker_available(),
      docker_images: docker_images,
      apptainer: detect_apptainer_available(),
      apptainer_images: apptainer_images,
      escript: detect_escript_available(),
      on_path: detect_provers_on_path()
    }
  end

  @doc """
  Returns a human-readable summary of the local execution environment
  (detection plus per-prover image status) — one call for the notebook.
  """
  @spec image_status_summary() :: binary()
  def image_status_summary do
    avail = detect_available()
    backend = resolve_backend(:auto)

    detection = """
    Detection:
      tableaux: #{avail.tableaux}   docker: #{avail.docker}   apptainer: #{avail.apptainer}
      escript:  #{avail.escript}    on PATH:  #{inspect(avail.on_path)}
      active build backend: #{backend}
    """

    rows =
      Prover.builtins()
      |> Enum.map(fn prover ->
        icon =
          case image_status(prover.name) do
            :available -> "✅"
            :needs_build -> "🏗️"
            :needs_pull -> "📥"
            :unavailable -> "❌"
          end

        "  #{icon} #{prover.name}"
      end)
      |> Enum.join("\n")

    detection <> "Images:\n" <> rows <> "\n"
  end

  @doc """
  Prints the local execution environment summary (detection + per-prover image
  status) directly — one call for the notebook.
  """
  @spec print_image_status_summary() :: :ok
  def print_image_status_summary, do: IO.puts(image_status_summary())

  @doc false
  def detect_apptainer_available do
    System.find_executable("apptainer") != nil or System.find_executable("singularity") != nil
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
        # Strip default registry prefix — Docker Desktop stores images without it
        query_tag = String.replace_prefix(img, "docker.io/", "")

        case run_cmd("docker", ["images", "-q", query_tag], []) do
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
  Set `force: true` to rebuild even when the image already exists.
  """
  @spec ensure_docker_image!(Prover.t() | atom() | binary(), keyword()) :: :ok
  def ensure_docker_image!(prover, opts \\ []) do
    prover = normalize_prover(prover)
    container = prover_metadata(prover.name) |> Map.get(:container)
    img = container && container.docker_image

    cond do
      is_nil(container) or is_nil(img) ->
        raise ArgumentError, "No Docker image defined for prover #{prover.name}"

      not Keyword.get(opts, :force, false) and docker_image_status(prover) == :available ->
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

    build_args =
      if Keyword.get(opts, :force, false) do
        ["build", "--no-cache", "-t", tag, "-f", abs_path, build_dir]
      else
        ["build", "-t", tag, "-f", abs_path, build_dir]
      end

    {output, exit_code} = run_cmd("docker", build_args, Keyword.get(opts, :cmd_opts, []))

    if exit_code != 0 do
      raise RuntimeError,
            "Failed to build Docker image #{tag}: #{String.slice(output, 0, 500)}"
    end

    :ok
  end

  @doc """
  Ensures a prover's Apptainer SIF exists locally, building it from its
  `apptainer.def` into `Config.sif_dir/0` when missing (or when `force: true`).
  """
  @spec ensure_apptainer_image!(Prover.t() | atom() | binary(), keyword()) :: :ok
  def ensure_apptainer_image!(prover, opts \\ []) do
    prover = normalize_prover(prover)

    if not Keyword.get(opts, :force, false) and apptainer_image_status(prover) == :available do
      :ok
    else
      build_apptainer_image!(prover, opts)
    end
  end

  @doc """
  Builds a prover's Apptainer SIF from its `apptainer.def` into `Config.sif_dir/0`.

  Uses `apptainer build --force` so an existing `.sif` is overwritten.
  """
  @spec build_apptainer_image!(Prover.t() | atom() | binary(), keyword()) :: :ok
  def build_apptainer_image!(prover, opts \\ []) do
    prover = normalize_prover(prover)
    container = prover_metadata(prover.name) |> Map.get(:container)

    def_path =
      case container && container.def_path do
        nil -> raise ArgumentError, "No apptainer.def defined for prover #{prover.name}"
        path -> local_def_path(path)
      end

    sif_path = local_sif_path(prover)
    File.mkdir_p!(Path.dirname(sif_path))

    IO.puts("Building Apptainer image: #{sif_path}")
    IO.puts("  from #{def_path}")

    cmd_opts = Keyword.get(opts, :cmd_opts, [])

    {output, exit_code} =
      run_cmd("apptainer", ["build", "--force"] ++ cmd_opts ++ [sif_path, def_path], [])

    if exit_code != 0 do
      raise RuntimeError,
            "Failed to build Apptainer image #{sif_path}: #{String.slice(output, 0, 500)}"
    end

    :ok
  end

  @doc """
  Builds (or pulls) images for all given provers in one call.

  `backend` selects the local build tool: `:auto` (default — Docker if
  available, else Apptainer), `:docker`, or `:apptainer`. Set `force: true`
  to rebuild every image even if already present.

  `provers` may be `:all` or a list of prover names. Returns a list of
  `{:ok, name}` / `{:error, name, reason}` and prints a progress summary.

      AtpBenchmarkRunner.build_local_images!(:all)
      AtpBenchmarkRunner.build_local_images!([:vampire, :eprover], force: true, backend: :apptainer)
  """
  @spec build_images!(atom() | [atom() | binary()], keyword()) ::
          [{:ok, atom()} | {:error, atom() | binary(), binary()}]
  def build_images!(provers, opts \\ [])

  def build_images!(:all, opts), do: build_images!(Prover.builtins(), opts)

  def build_images!(provers, opts) when is_list(provers) do
    backend = resolve_backend(Keyword.get(opts, :backend, :auto))
    force = Keyword.get(opts, :force, false)

    results =
      Enum.map(provers, fn name_or_prover ->
        try do
          prover = normalize_prover(name_or_prover)
          build_one_image!(prover, backend, force)
          {:ok, prover.name}
        rescue
          e -> {:error, result_name(name_or_prover), Exception.message(e)}
        end
      end)

    print_build_summary(results)
  end

  defp result_name(%Prover{name: name}), do: name
  defp result_name(name), do: name

  defp build_one_image!(%Prover{} = prover, backend, force) do
    case backend do
      :docker -> ensure_docker_image!(prover, force: force)
      :apptainer -> ensure_apptainer_image!(prover, force: force)
    end

    :ok
  end

  defp resolve_backend(:auto) do
    if detect_docker_available(), do: :docker, else: :apptainer
  end

  defp resolve_backend(backend) when backend in [:docker, :apptainer], do: backend

  defp image_status(prover) do
    case resolve_backend(:auto) do
      :docker -> docker_image_status(prover)
      :apptainer -> apptainer_image_status(prover)
    end
  end

  defp local_def_path(def_path) do
    app_root = :code.priv_dir(:atp_benchmark_runner) |> to_string() |> Path.dirname()
    Path.expand(def_path, app_root)
  end

  defp print_build_summary(results) do
    success = Enum.count(results, &match?({:ok, _}, &1))
    failure = Enum.count(results, &match?({:error, _, _}, &1))
    IO.puts("\n#{success} built, #{failure} failed")

    failed = Enum.filter(results, &match?({:error, _, _}, &1))

    if failed != [] do
      IO.puts("Failed: #{Enum.map_join(failed, ", ", fn {:error, name, _} -> name end)}")
    end

    results
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

    # Pre-build/pull images for all containerized provers. Provers that run via
    # a local escript (declared `local_execution: :escript` — e.g. tableaux)
    # need no image. `:backend` and `:force` flow through.
    if auto_ensure do
      build_images!(
        Enum.reject(provers, &(&1.local_execution != :container)),
        backend: Keyword.get(opts, :backend, :auto),
        force: Keyword.get(opts, :force, false)
      )
    end

    case execution_strategy do
      :sequential_containers ->
        # Run all problems for one prover before switching to next prover
        # This reduces container loading times since each container starts once
        Enum.flat_map(provers, fn prover ->
          compatible = filter_compatible_problems(prover, problems)

          if compatible != problems do
            skipped_ids = MapSet.new(compatible, & &1.id)
            skipped = Enum.reject(problems, &MapSet.member?(skipped_ids, &1.id))

            IO.puts(
              "   ⚠ #{prover.name}: skipping #{length(skipped)} problem(s) (incompatible logic — UnsupportedLogic)"
            )

            skipped_results =
              Enum.map(skipped, fn problem ->
                Result.new(%{
                  problem_id: problem.id,
                  prover: prover.name,
                  szs_status: "UnsupportedLogic",
                  wall_time_ms: 0,
                  metadata: %{reason: incompatible_reason(prover, problem)}
                })
              end)

            compatible_results =
              Enum.map(compatible, fn problem ->
                run_one(prover, problem, timeout_seconds, include_raw_output, verbose)
              end)

            compatible_results ++ skipped_results
          else
            Enum.map(compatible, fn problem ->
              run_one(prover, problem, timeout_seconds, include_raw_output, verbose)
            end)
          end
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

    case prover.local_execution do
      :escript ->
        local_tableaux_command(problem_path, timeout_seconds)

      :container ->
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
            query_tag = String.replace_prefix(img, "docker.io/", "")

            case run_cmd("docker", ["images", "-q", query_tag], []) do
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

  @doc false
  def check_apptainer_images do
    Map.new(Prover.builtins(), fn prover -> {prover.name, apptainer_image_status(prover.name)} end)
  end

  @doc """
  Returns the status of a prover's locally-built Apptainer SIF.
  Returns `:available`, `:needs_build`, or `:unavailable`.
  """
  @spec apptainer_image_status(Prover.t() | atom() | binary()) :: atom()
  def apptainer_image_status(prover) do
    prover = normalize_prover(prover)
    container = prover_metadata(prover.name) |> Map.get(:container)

    cond do
      is_nil(container) or is_nil(container.def_path) ->
        :unavailable

      File.exists?(local_sif_path(prover)) ->
        :available

      true ->
        :needs_build
    end
  end

  @doc false
  @spec local_sif_path(Prover.t() | atom() | binary()) :: binary()
  def local_sif_path(%Prover{} = prover) do
    sif_name = prover.sif_name || Atom.to_string(prover.name)
    Path.join(Config.sif_dir(), "#{sif_name}.sif")
  end

  def local_sif_path(name), do: name |> normalize_prover() |> local_sif_path()

  # --- Prover execution ---

  defp run_one(
         %Prover{local_execution: :escript} = prover,
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
        Result.from_output(prover, problem_id, output,
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
      cond do
        # Local Apptainer is available and the prover's SIF is built locally.
        detect_apptainer_available() and File.exists?(local_sif_path(prover)) ->
          run_apptainer(prover, problem_path, timeout_seconds, verbose)

        # Fall back to Docker for containerized provers.
        detect_docker_available() ->
          run_via_docker(prover, problem_path, command, timeout_seconds, verbose)

        # Try the native binary stripped of the apptainer prefix.
        true ->
          run_native_stripped(command)
      end
    else
      # Plain CLI command
      [exe | args] = String.split(command, " ", trim: true)

      case System.find_executable(exe) do
        nil ->
          {:gaveup, "Executable '#{exe}' not found on PATH. Install it or use Docker/Apptainer."}

        _ ->
          wall_start = System.monotonic_time(:millisecond)
          {output, exit_code} = run_cmd(exe, args, [])
          wall_end = System.monotonic_time(:millisecond)
          {:ok, output, exit_code, wall_end - wall_start}
      end
    end
  end

  # Runs a containerized prover through the local Apptainer binary. The problem
  # (or converted SMT/THF input) is bind-mounted to /problems, matching the
  # Docker path so the same command templates work on Linux/macOS.
  defp run_apptainer(prover, problem_path, timeout_seconds, verbose) do
    problem_id = Path.rootname(problem_path) |> Path.basename()
    sif_path = local_sif_path(prover)

    {mount_dir, mount_file} = Input.local_mount(prover, problem_path)

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
        |> String.replace("{sif_path}", sif_path)
        |> String.replace("{cores}", "1")
      end)

    args = ["exec", "--bind", "#{mount_dir}:/problems", sif_path] ++ prover_args

    if verbose do
      IO.puts("")
      IO.puts("🐳 [#{problem_id}] apptainer #{Enum.join(args, " ")}")
    end

    wall_start = System.monotonic_time(:millisecond)
    {output, exit_code} = run_cmd("apptainer", args, [])
    wall_end = System.monotonic_time(:millisecond)

    {:ok, output, exit_code, wall_end - wall_start}
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

    # Generic input preparation: the prover's `input` field decides whether the
    # raw `.p` is used or a converted SMT-LIB/THF file is produced first.
    {mount_dir, mount_file} =
      Input.local_mount(prover, problem_path)
      |> then(fn {dir, file} -> {docker_path(dir), file} end)

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
        |> String.replace("{cores}", "1")
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

    # No per-prover output rewriting: the prover's declared `parser`
    # (`:szs` / `:smt_bare` / custom) handles status extraction in Result.
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
    flags = tableaux_cli_flags()

    cond do
      File.exists?(escript) and detect_escript_available() ->
        {"escript", [escript] ++ flags ++ [problem_path], []}

      File.exists?(Path.join(solver_root, "mix.exs")) ->
        {"mix",
         ["run", "--no-start", Path.join(solver_root, "run.exs"), "--"] ++ flags ++ [problem_path],
         [cd: solver_root]}

      true ->
        {"echo", ["tableaux solver not available"], []}
    end
  end

  # Derive the tableaux CLI flags from its prover.exs command_template so the
  # local escript invocation can never drift from the container invocation.
  defp tableaux_cli_flags do
    "apptainer exec {sif_path} simple_tableaux_solver "
    |> then(&String.replace_prefix(Prover.builtin!(:tableaux).command_template, &1, ""))
    |> String.replace("{problem}", "")
    |> String.split(" ", trim: true)
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
      # The AISE tableaux solver emits its own authoritative `% SZS status` line.
      # Its internal log lines (e.g. `status: SAT` when a theorem is not refuted)
      # must NOT override that explicit status, so read the raw token first.
      status = Result.explicit_szs_status(output) ->
        status

      # SZS status inferred from output
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
    case AtpBenchmarkRunner.Provers.fetch(name) do
      {:ok, prover} ->
        %{prover: prover, container: AtpBenchmarkRunner.Provers.container!(prover.name)}

      :error ->
        nil
    end
  end

  @known_supported_logics ~w(fof cnf tff thf type axiom conjecture hypothesis
                               and or not impl equiv true false include)

  # --- Logic compatibility filtering ---

  @doc """
  Filters problems to only those whose logic is supported by the prover.

  Driven by the prover spec's `supports` map:

    * `supports.forms` — a list of logic prefixes (`[:cnf, :fof, ...]`) filters
      by the problem's logic; `:all` (default) keeps everything.
    * `supports.requires_conjecture?` — when `true`, skips Satisfiable problems
      with no conjecture (refutation provers such as Lash cannot determine
      plain Satisfiable from axioms alone). THF problems are always kept.
  """
  @spec filter_compatible_problems(Prover.t(), [Problem.t()]) :: [Problem.t()]
  def filter_compatible_problems(%Prover{} = prover, problems) do
    supports = prover.supports || %{}
    forms = Map.get(supports, :forms, :all)
    requires_conjecture? = Map.get(supports, :requires_conjecture?, false)

    problems
    |> maybe_filter_by_forms(forms)
    |> maybe_filter_by_conjecture(requires_conjecture?)
  end

  defp maybe_filter_by_forms(problems, forms) when is_list(forms) and forms != [] do
    Enum.filter(problems, fn problem ->
      String.to_atom(logic_prefix(problem)) in forms
    end)
  end

  defp maybe_filter_by_forms(problems, _forms), do: problems

  defp maybe_filter_by_conjecture(problems, true) do
    Enum.filter(problems, &compatible_refutation?/1)
  end

  defp maybe_filter_by_conjecture(problems, _), do: problems

  defp logic_prefix(%Problem{logic: logic}) when is_binary(logic) do
    logic |> String.split("_") |> List.first() |> String.downcase()
  end

  defp logic_prefix(_problem), do: "unknown"

  # A refutation prover proves theorems but cannot determine plain Satisfiable
  # from axioms alone (it needs a conjecture); THF problems are always kept.
  defp compatible_refutation?(%Problem{logic: logic, path: path, expected_status: expected})
       when is_binary(logic) do
    prefix = logic |> String.split("_") |> List.first() |> String.downcase()

    cond do
      prefix in ~w(thf th0) -> true
      not has_conjecture?(path) and expected == "Satisfiable" -> false
      true -> true
    end
  end

  defp compatible_refutation?(_problem), do: false

  # Human-readable reason for a problem skipped as incompatible.
  defp incompatible_reason(%Prover{} = prover, %Problem{} = problem) do
    supports = prover.supports || %{}
    forms = Map.get(supports, :forms, :all)
    requires_conjecture? = Map.get(supports, :requires_conjecture?, false)
    logic = problem.logic || "unknown"

    cond do
      is_list(forms) and forms != [] and
          String.to_atom(logic_prefix(problem)) not in forms ->
        "#{prover.label} does not support #{logic} problems " <>
          "(supports: #{Enum.join(forms, ", ")})"

      requires_conjecture? and not has_conjecture?(problem.path) and
          problem.expected_status == "Satisfiable" ->
        "#{prover.label} is a refutation prover; #{problem.name} has no conjecture and is " <>
          "Satisfiable — it cannot determine satisfiability."

      true ->
        "#{prover.label} is incompatible with #{problem.name} (#{logic})."
    end
  end

  # ── Lash compatibility helpers ──────────────────────────────────────────────

  @doc false
  def lash_compatible?(%Problem{logic: logic, path: path, expected_status: expected})
      when is_binary(logic) do
    prefix = logic |> String.split("_") |> List.first() |> String.downcase()

    cond do
      prefix in ~w(thf th0) ->
        true

      not has_conjecture?(path) and expected == "Satisfiable" ->
        # Lash is a refutation prover — without a conjecture it can only
        # detect Unsatisfiable (axiom contradictions). It cannot determine
        # plain Satisfiable from axioms alone.
        false

      true ->
        true
    end
  end

  def lash_compatible?(_problem), do: false

  @doc false
  def has_function_symbols?(path) do
    content = File.read!(path)

    # Remove comments and blank lines, join into one flat line
    flat =
      content
      |> String.split(~r/[\r\n]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.starts_with?(&1, "%") or &1 == ""))
      |> Enum.join(" ")

    # Strip formula headers (fof|cnf|tff|thf(name, role, ) leaving only body content)
    # This avoids matching TPTP formula names like `some_identity(` in
    # `fof(some_identity, axiom, ...)`.
    # The replacement leaves unbalanced content (extra ) and .) but that's fine
    # for the regex scan — we only care about `word(` patterns.
    body_only =
      Regex.replace(
        ~r/(?:fof|cnf|tff|thf)\(\s*[^,]+?\s*,\s*[^,]+?\s*,\s*/,
        flat,
        ""
      )

    # Scan remaining content for `word(` patterns (potential function symbols)
    matches = Regex.scan(~r/\b([a-z_][a-zA-Z0-9_]*)\s*\(/, body_only)

    Enum.any?(matches, fn [_, name] -> name not in @known_supported_logics end)
  end

  @doc false
  def has_conjecture?(path) do
    content = File.read!(path)
    String.match?(content, ~r/\bconjecture\b/i)
  end
end
