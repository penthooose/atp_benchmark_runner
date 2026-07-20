defmodule AtpBenchmarkRunner.HPC.NodeResources do
  @moduledoc """
  Dynamically detects CPU core count and total RAM on a cluster node via SSH.

  Falls back to the static known-good table (`Config.node_total_cpus/2` and
  a default RAM estimate) when the SSH probe fails or is not available.
  """

  alias AtpBenchmarkRunner.HPC.Config, as: HPCConfig

  @default_ram_mb_per_core 1_900

  @doc """
  Probes the cluster login node (or a compute node via allocation) for actual
  CPU core count and total RAM.

  Returns `%{cpus: pos_integer(), ram_mb: pos_integer()}`.

  Falls back to the static `Config.node_total_cpus/2` table and a RAM estimate
  if the SSH probe fails.
  """
  @spec probe(HpcConnect.Session.t(), keyword()) :: %{cpus: pos_integer(), ram_mb: pos_integer()}
  def probe(%HpcConnect.Session{} = session, opts \\ []) do
    use_dynamic = Keyword.get(opts, :dynamic_resources, false)

    if use_dynamic do
      do_probe(session, opts)
    else
      static_fallback(session, opts)
    end
  end

  @doc """
  Converts a raw `cpus` value from probe/fallback into the per-prover allocation
  based on `hpc_mode`, `single_node_mode`, `prover_count`, and `node_size`.
  """
  @spec allocate_cpus(
          cpus_total :: pos_integer(),
          ram_mb_total :: pos_integer(),
          keyword()
        ) :: %{cpus_per_task: pos_integer() | nil, mem: binary() | nil}
  def allocate_cpus(cpus_total, ram_mb_total, opts) do
    hpc_mode = Keyword.get(opts, :hpc_mode, :single_node)
    single_node_mode = Keyword.get(opts, :single_node_mode, :sequential)
    _prover_count = max(Keyword.get(opts, :prover_count, 1), 1)
    max_parallel = max(Keyword.get(opts, :max_parallel_jobs, 4), 1)
    node_size = Keyword.get(opts, :node_size, :full)
    half = node_size == :half

    available_cpus = if half, do: max(div(cpus_total, 2), 1), else: cpus_total
    available_ram = if half, do: div(ram_mb_total, 2), else: ram_mb_total

    {cpus_per_task, mem_per_job} =
      case hpc_mode do
        :multi_node ->
          # Each prover on its own node → full (or half) node resources per job
          {nil, "#{available_ram}M"}

        :single_node ->
          case single_node_mode do
            :sequential ->
              # One task at a time → each gets the full allocation
              {available_cpus, "#{available_ram}M"}

            :parallel ->
              # Spread CPUs across concurrent tasks
              per_task = max(div(available_cpus, max_parallel), 1)
              per_task_ram = max(div(available_ram, max_parallel), 1)
              {per_task, "#{per_task_ram}M"}
          end
      end

    %{cpus_per_task: cpus_per_task, mem: mem_per_job}
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp do_probe(session, opts) do
    cpu_result = probe_cpus(session, opts)
    ram_result = probe_ram(session, opts)

    cpus =
      case cpu_result do
        {:ok, n} when n > 0 ->
          n

        _ ->
          IO.puts("[NodeResources] CPU probe failed, fallback to static table")
          HPCConfig.node_total_cpus(session.cluster.name, Keyword.get(opts, :partition, "cpu"))
      end

    ram_mb =
      case ram_result do
        {:ok, mb} when mb > 0 ->
          mb

        _ ->
          IO.puts("[NodeResources] RAM probe failed, estimating from CPU count")
          cpus * @default_ram_mb_per_core
      end

    %{cpus: cpus, ram_mb: ram_mb}
  end

  defp probe_cpus(session, opts) do
    output =
      HpcConnect.connect!(session, "nproc --all 2>/dev/null || echo 0",
        connect_opts: Keyword.get(opts, :connect_opts, [])
      )

    case Integer.parse(String.trim(output)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp probe_ram(session, opts) do
    output =
      HpcConnect.connect!(
        session,
        "awk '/MemTotal/ {printf \"%d\", $2/1024}' /proc/meminfo 2>/dev/null || echo 0",
        connect_opts: Keyword.get(opts, :connect_opts, [])
      )

    case Integer.parse(String.trim(output)) do
      {mb, ""} when mb > 0 -> {:ok, mb}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp static_fallback(session, opts) do
    cpus = HPCConfig.node_total_cpus(session.cluster.name, Keyword.get(opts, :partition, "cpu"))
    %{cpus: cpus, ram_mb: cpus * @default_ram_mb_per_core}
  end
end
