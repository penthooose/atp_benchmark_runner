defmodule AtpBenchmarkRunner.HPC.Runner do
  @moduledoc """
  Runs benchmarks on HPC clusters via `hpc_connect`.

  Modes: `:single_node` (default, all provers on one node) or `:multi_node`.

      session = HpcConnect.Session.local()
      AtpBenchmarkRunner.HPC.Runner.bootstrap(session, provers, problems,
        mode: :hpc, hpc_mode: :single_node
      )
  """

  alias AtpBenchmarkRunner.{Problem, Prover}

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
    hpc_mode = Keyword.get(opts, :hpc_mode, :single_node)

    case hpc_mode do
      :single_node ->
        run_single_node(session, provers, problems, opts)

      :multi_node ->
        run_multi_node(session, provers, problems, opts)

      _ ->
        raise ArgumentError,
              "Unknown HPC mode: #{inspect(hpc_mode)}. Expected :single_node or :multi_node."
    end
  end

  @doc """
  Single-node execution: All provers run on one compute node as a job array.

  Each prover runs sequentially on the same node, with one SLURM job array
  containing all prover/problem combinations.
  """
  @spec run_single_node(
          HpcConnect.Session.t(),
          [Prover.t() | atom() | binary()],
          [Problem.t() | binary()],
          keyword()
        ) :: map()
  def run_single_node(_session, _provers, _problems, _opts \\ []) do
    # TODO: Implement single-node job array execution
    # For now, return a stub result
    IO.puts("⚠️  Single-node HPC execution not yet implemented")
    IO.puts("   This mode will run all provers on one compute node as a job array")

    %{
      results: [],
      job_ids: %{},
      run: nil,
      note: "Single-node HPC execution not yet implemented"
    }
  end

  @doc """
  Multi-node execution: Each prover runs on a separate compute node.

  Submits one SLURM job per prover, with each job running all problems
  for that prover (job array per prover).
  """
  @spec run_multi_node(
          HpcConnect.Session.t(),
          [Prover.t() | atom() | binary()],
          [Problem.t() | binary()],
          keyword()
        ) :: map()
  def run_multi_node(_session, _provers, _problems, _opts \\ []) do
    # TODO: Implement multi-node parallel execution
    # For now, return a stub result
    IO.puts("⚠️  Multi-node HPC execution not yet implemented")
    IO.puts("   This mode will run one prover per compute node")

    %{
      results: [],
      job_ids: %{},
      run: nil,
      note: "Multi-node HPC execution not yet implemented"
    }
  end
end
