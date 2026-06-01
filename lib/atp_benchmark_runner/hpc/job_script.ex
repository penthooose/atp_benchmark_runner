defmodule AtpBenchmarkRunner.HPC.JobScript do
  @moduledoc """
  Builds SLURM job-array scripts for prover/problem matrix runs.
  """

  alias AtpBenchmarkRunner.{Prover, Run}
  alias AtpBenchmarkRunner.HPC.Shell

  @doc """
  Returns all remote paths used by a run.
  """
  @spec remote_paths(Run.t(), binary()) :: map()
  def remote_paths(%Run{} = run, remote_root) when is_binary(remote_root) do
    run_dir = posix_join(remote_root, run.id)

    %{
      run_dir: run_dir,
      scripts_dir: posix_join(run_dir, "scripts"),
      logs_dir: posix_join(run_dir, "logs"),
      results_dir: posix_join(run_dir, "results"),
      problem_list: posix_join(run_dir, "problems.txt")
    }
  end

  @doc """
  Builds the newline-separated remote problem list consumed by SLURM array tasks.
  """
  @spec problem_list(Run.t()) :: binary()
  def problem_list(%Run{} = run) do
    run.problems
    |> Enum.map(fn problem -> problem.path || problem.name end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Builds one executable SLURM script for a prover.
  """
  @spec build(Run.t(), Prover.t(), binary(), keyword()) :: binary()
  def build(%Run{} = run, %Prover{} = prover, remote_root, opts \\ []) do
    paths = remote_paths(run, remote_root)
    max_parallel = Keyword.get(opts, :max_parallel_jobs, run.max_parallel_jobs)
    partition_line = if run.partition, do: "#SBATCH --partition=#{run.partition}", else: ""
    cpus_line = cpus_line(opts)
    array_size = max(length(run.problems), 1)
    prover_name = Atom.to_string(prover.name)
    prover_results = posix_join(paths.results_dir, prover_name)
    command = runtime_command(prover, run.problem_timeout_seconds, opts)

    """
    #!/bin/bash -l
    #SBATCH --job-name=atp_#{safe_job_token(run.id)}_#{safe_job_token(prover_name)}
    #{partition_line}
    #SBATCH --array=1-#{array_size}%#{max_parallel}
    #{cpus_line}
    #SBATCH --time=#{run.walltime}
    #SBATCH --output=#{paths.logs_dir}/#{prover_name}_%A_%a.out
    #SBATCH --error=#{paths.logs_dir}/#{prover_name}_%A_%a.err
    #SBATCH --export=NONE

    unset SLURM_EXPORT_ENV
    set -uo pipefail

    export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
    export OMP_PLACES=cores
    export OMP_PROC_BIND=true
    export SRUN_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"

    PROVER=#{Shell.quote(prover_name)}
    PROBLEM_FILE=#{Shell.quote(paths.problem_list)}
    RESULT_DIR=#{Shell.quote(prover_results)}
    TIMEOUT_SECONDS=#{run.problem_timeout_seconds}

    mkdir -p "$RESULT_DIR"

    PROBLEM_PATH=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$PROBLEM_FILE")
    if [ -z "$PROBLEM_PATH" ]; then
      echo "No problem for SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID}" >&2
      exit 2
    fi

    PROBLEM_BASENAME=$(basename "$PROBLEM_PATH")
    PROBLEM_ID="${PROBLEM_BASENAME%.*}"
    OUT_FILE="$RESULT_DIR/${PROBLEM_ID}.out"
    META_FILE="$RESULT_DIR/${PROBLEM_ID}.meta.json"
    RESOURCE_FILE="$RESULT_DIR/${PROBLEM_ID}.resources.txt"
    export PROBLEM_PATH OUT_FILE META_FILE RESOURCE_FILE TIMEOUT_SECONDS

    START_EPOCH_MS=$(date +%s%3N)
    EXIT_STATUS=0

    if command -v /usr/bin/time >/dev/null 2>&1; then
      /usr/bin/time -f 'elapsed_seconds=%e\nmax_rss_kb=%M' -o "$RESOURCE_FILE" \
        timeout --preserve-status "${TIMEOUT_SECONDS}s" bash -lc #{Shell.quote(command)} > "$OUT_FILE" 2>&1 || EXIT_STATUS=$?
    else
      timeout --preserve-status "${TIMEOUT_SECONDS}s" bash -lc #{Shell.quote(command)} > "$OUT_FILE" 2>&1 || EXIT_STATUS=$?
    fi

    END_EPOCH_MS=$(date +%s%3N)
    WALL_TIME_MS=$((END_EPOCH_MS - START_EPOCH_MS))
    MEMORY_KB=null

    if [ -f "$RESOURCE_FILE" ]; then
      PARSED_MEMORY=$(awk -F= '$1 == "max_rss_kb" {print $2; exit}' "$RESOURCE_FILE")
      if echo "$PARSED_MEMORY" | grep -Eq '^[0-9]+$'; then
        MEMORY_KB="$PARSED_MEMORY"
      fi
    fi

    if ! grep -qi "SZS status" "$OUT_FILE"; then
      if [ "$EXIT_STATUS" = "124" ] || [ "$EXIT_STATUS" = "137" ]; then
        echo "% SZS status Timeout for ${PROBLEM_ID}" >> "$OUT_FILE"
      else
        echo "% SZS status GaveUp for ${PROBLEM_ID}" >> "$OUT_FILE"
      fi
    fi

    printf '{"problem_id":"%s","prover":"%s","exit_status":%s,"wall_time_ms":%s,"memory_kb":%s,"output_path":"%s","resource_path":"%s"}\n' \
      "$PROBLEM_ID" "$PROVER" "$EXIT_STATUS" "$WALL_TIME_MS" "$MEMORY_KB" "$OUT_FILE" "$RESOURCE_FILE" > "$META_FILE"

    exit 0
    """
  end

  @doc """
  Builds a remote command that writes a file from base64 content.
  """
  @spec write_file_command(binary(), binary(), keyword()) :: binary()
  def write_file_command(remote_path, content, opts \\ []) do
    mode = Keyword.get(opts, :mode)
    dir = posix_dirname(remote_path)
    b64 = content |> String.replace("\r", "") |> Base.encode64()

    chmod = if mode, do: " && chmod #{mode} #{Shell.quote(remote_path)}", else: ""

    "mkdir -p #{Shell.quote(dir)} && printf %s #{Shell.quote(b64)} | base64 -d > #{Shell.quote(remote_path)}#{chmod}"
  end

  @doc false
  @spec runtime_command(Prover.t(), pos_integer(), keyword()) :: binary()
  def runtime_command(%Prover{} = prover, timeout_seconds, opts \\ []) do
    sif_path =
      Keyword.get(opts, :sif_path) ||
        prover.sif_path ||
        if(prover.sif_name,
          do:
            "${HPC_WORK_DIR:-$HOME/.cache/hpc_connect}/singularity_images/#{prover.sif_name}.sif"
        )

    rendered_sif_path =
      if is_binary(sif_path) and String.starts_with?(sif_path, "${") do
        "\"#{sif_path}\""
      else
        Shell.quote(sif_path || "")
      end

    replacements = %{
      "{problem}" => "\"$PROBLEM_PATH\"",
      "{result_file}" => "\"$OUT_FILE\"",
      "{timeout_seconds}" => to_string(timeout_seconds),
      "{timeout_ms}" => to_string(timeout_seconds * 1_000),
      "{sif_path}" => rendered_sif_path
    }

    Enum.reduce(replacements, prover.command_template, fn {placeholder, value}, acc ->
      String.replace(acc, placeholder, value)
    end)
  end

  defp cpus_line(opts) do
    case Keyword.get(opts, :cpus_per_task) do
      nil -> ""
      cpus -> "#SBATCH --cpus-per-task=#{cpus}"
    end
  end

  defp safe_job_token(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
    |> String.slice(0, 32)
  end

  defp posix_join(left, right) do
    [String.trim_trailing(left, "/"), String.trim_leading(right, "/")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end

  defp posix_dirname(path) do
    normalized = String.replace(path, "\\", "/")

    normalized
    |> String.split("/", trim: true)
    |> Enum.drop(-1)
    |> case do
      [] ->
        if String.starts_with?(normalized, "/"), do: "/", else: "."

      parts ->
        if String.starts_with?(normalized, "/"),
          do: "/" <> Enum.join(parts, "/"),
          else: Enum.join(parts, "/")
    end
  end
end
