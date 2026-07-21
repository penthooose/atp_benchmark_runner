defmodule AtpBenchmarkRunner.HPC.Config do
  @moduledoc """
  Resolves env-backed HPC benchmark settings.

  The session owns SSH / filesystem connectivity. This module only resolves
  runner-specific defaults such as partition, shared-node sizing, polling, and
  remote artifact locations.
  """

  alias AtpBenchmarkRunner.Config, as: RootConfig

  @terminal_states MapSet.new([
                     "BOOT_FAIL",
                     "CANCELLED",
                     "COMPLETED",
                     "DEADLINE",
                     "FAILED",
                     "NODE_FAIL",
                     "OUT_OF_MEMORY",
                     "PREEMPTED",
                     "TIMEOUT"
                   ])

  @spec resolve(HpcConnect.Session.t(), keyword()) :: map()
  def resolve(%HpcConnect.Session{} = session, opts \\ []) do
    hpc_mode = atom_value(opts, :hpc_mode, "MODE", :single_node, [:single_node, :multi_node])
    max_parallel_jobs = int_value(opts, :max_parallel_jobs, "MAX_PARALLEL_JOBS", 4)
    prover_count = max(int_from_opt(opts, :prover_count) || 0, 1)

    single_node_mode =
      atom_value(opts, :single_node_mode, "SINGLE_NODE_MODE", :sequential, [
        :parallel,
        :sequential
      ])

    node_size =
      atom_value(
        opts,
        :node_size,
        "NODE_SIZE",
        cluster_default_node_size(session.cluster.name),
        [:full, :half]
      )

    partition = string_value(opts, :partition, "PARTITION", "cpu")
    total_cpus = __MODULE__.node_total_cpus(session.cluster.name, partition)

    # Dynamic resource probe (SSH) — opt-in via :dynamic_resources or env var.
    dynamic_resources =
      bool_value(opts, :dynamic_resources, "DYNAMIC_RESOURCES", false)

    resources =
      if dynamic_resources do
        AtpBenchmarkRunner.HPC.NodeResources.probe(session,
          partition: partition,
          dynamic_resources: true,
          connect_opts: Keyword.get(opts, :connect_opts, [])
        )
      else
        %{cpus: total_cpus, ram_mb: total_cpus * 1_900}
      end

    total_ram_mb = resources.ram_mb

    %{
      cluster: atom_or_string_value(opts, :cluster, "CLUSTER", session.cluster.name),
      node_kind: string_value(opts, :node_kind, "NODE_KIND", "cpu"),
      partition: partition,
      node_size: node_size,
      total_cpus: resources.cpus,
      total_ram_mb: total_ram_mb,
      hpc_mode: hpc_mode,
      single_node_mode: single_node_mode,
      single_node_strategy:
        atom_value(
          opts,
          :single_node_strategy,
          "SINGLE_NODE_STRATEGY",
          :direct_provers,
          [:parallel_sifs, :direct_provers, :bundled_container]
        ),
      walltime: string_value(opts, :walltime, "WALLTIME", "02:00:00"),
      max_parallel_jobs: max_parallel_jobs,
      cpus_per_task:
        optional_int_value(
          opts,
          :cpus_per_task,
          "CPUS_PER_TASK",
          default_cpus(
            hpc_mode,
            single_node_mode,
            max_parallel_jobs,
            prover_count,
            node_size,
            resources.cpus
          )
        ),
      ntasks: int_value(opts, :ntasks, "NTASKS", 1),
      nodes: optional_int_value(opts, :nodes, "NODES", default_nodes(hpc_mode)),
      gres: optional_string_value(opts, :gres, "GRES"),
      constraint: optional_string_value(opts, :constraint, "CONSTRAINT"),
      mem:
        optional_string_value(
          opts,
          :mem,
          "MEM",
          default_mem(
            hpc_mode,
            single_node_mode,
            max_parallel_jobs,
            prover_count,
            node_size,
            resources.ram_mb
          )
        ) || nil,
      exclusive:
        bool_value(
          opts,
          :exclusive,
          "EXCLUSIVE",
          default_exclusive(hpc_mode, single_node_mode, node_size)
        ),
      prepare_images: bool_value(opts, :prepare_images, "PREPARE_IMAGES", false),
      wait_for_completion: bool_value(opts, :wait_for_completion, "WAIT_FOR_COMPLETION", true),
      debug: bool_value(opts, :debug, "DEBUG", false),
      poll_interval_ms: int_value(opts, :poll_interval_ms, "POLL_INTERVAL_MS", 10_000),
      max_wait_ms: int_value(opts, :max_wait_ms, "MAX_WAIT_MS", 12 * 60 * 60 * 1_000),
      include_raw_output: bool_value(opts, :include_raw_output, "INCLUDE_RAW_OUTPUT", false),
      remote_root:
        string_value(
          opts,
          :remote_root,
          "REMOTE_ROOT",
          posix_join(session.vault_dir || session.work_dir, "atp_benchmark_runner")
        ),
      remote_tptp_dir:
        string_value(
          opts,
          :remote_tptp_dir,
          "REMOTE_TPTP_DIR",
          posix_join(
            posix_join(session.vault_dir || session.work_dir, "atp_benchmark_runner"),
            "tptp"
          )
        )
    }
  end

  @spec terminal_state?(binary() | nil) :: boolean()
  def terminal_state?(state) when is_binary(state) do
    normalized = state |> String.trim() |> String.split([" ", "+"], parts: 2) |> hd()
    MapSet.member?(@terminal_states, normalized)
  end

  def terminal_state?(_), do: false

  # ── default_cpus ──────────────────────────────────────────────────────────
  # Full node, sequential: all node CPUs. --exclusive + --cpus-per-task=total
  # is needed because hpc_connect's normalize_apptainer_cpu_shape uses the
  # cpus-per-task value to round up to full nodes (Helma: rounds up to 48-core
  # chunks; nil → 1 → 48 instead of 384).
  defp default_cpus(:single_node, :sequential, _max_parallel, _prover_count, :full, total),
    do: total

  # Full node, parallel: spread CPUs across concurrent tasks so each one
  # gets enough cores for multi-threaded provers (Leo-III --cores, E auto-schedule).
  # --exclusive ensures the whole node is allocated regardless.
  defp default_cpus(:single_node, :parallel, max_parallel, _prover_count, :full, total),
    do: max(div(total, max(max_parallel, 1)), 1)

  # Half node, sequential: one task uses half the node's CPUs.
  defp default_cpus(:single_node, :sequential, _max_parallel, _prover_count, :half, total),
    do: half_cpus(total)

  # Half node, parallel: spread half the CPUs across concurrent tasks.
  defp default_cpus(:single_node, :parallel, max_parallel, _prover_count, :half, total) do
    max(div(half_cpus(total), max(max_parallel, 1)), 1)
  end

  # Multi-node, full: prover gets its own exclusive node.
  defp default_cpus(:multi_node, _mode, _max_parallel, _prover_count, :full, total),
    do: total

  # Multi-node, half: each prover uses half a node's CPUs.
  defp default_cpus(:multi_node, _mode, _max_parallel, _prover_count, :half, total),
    do: half_cpus(total)

  # ── default_mem ───────────────────────────────────────────────────────────
  # Mirror of default_cpus/6 but returns MB as a SLURM --mem string.
  # Returns nil when --exclusive gives the full node (no explicit --mem needed).

  defp default_mem(:single_node, :sequential, _max_parallel, _prover_count, :full, _ram),
    do: nil

  defp default_mem(:single_node, :parallel, max_parallel, _prover_count, :full, ram) do
    "#{max(div(ram, max(max_parallel, 1)), 1)}M"
  end

  defp default_mem(:single_node, :sequential, _max_parallel, _prover_count, :half, ram) do
    "#{half_cpus(ram)}M"
  end

  defp default_mem(:single_node, :parallel, max_parallel, _prover_count, :half, ram) do
    "#{max(div(half_cpus(ram), max(max_parallel, 1)), 1)}M"
  end

  defp default_mem(:multi_node, _mode, _max_parallel, _prover_count, :full, _ram), do: nil

  defp default_mem(:multi_node, _mode, _max_parallel, _prover_count, :half, ram),
    do: "#{half_cpus(ram)}M"

  # ── default_nodes ─────────────────────────────────────────────────────────
  # No explicit --nodes; SLURM auto-determines nodes from --cpus-per-task.
  # See sbatch.interactive.helma_cpu and sbatch.interactive.fritz_cpu.
  defp default_nodes(_mode), do: nil

  # ── default_exclusive ─────────────────────────────────────────────────────
  # Full node: always exclusive — we want the entire node.
  defp default_exclusive(_mode, _seq_or_par, :full), do: true

  # Half node: share the node with other jobs.
  defp default_exclusive(_mode, _seq_or_par, :half), do: false

  # ── cluster_default_node_size ─────────────────────────────────────────────
  # Default to half nodes for efficient cluster use; users can override.
  defp cluster_default_node_size(_cluster), do: :full

  # ── node_total_cpus (public for NodeResources fallback) ──────────────────
  # Helma CPU partition: 2 × AMD Turin ("Zen5c"), 192 cores each = 384 total.
  def node_total_cpus(:helma, "cpu"), do: 384
  def node_total_cpus(:helma, _partition), do: 384

  # Fritz Ice Lake nodes (singlenode / multinode): 2 × 36 cores = 72 total.
  def node_total_cpus(:fritz, "singlenode"), do: 72
  def node_total_cpus(:fritz, "multinode"), do: 72

  # Fritz Sapphire Rapids nodes (spr1tb / spr2tb): 2 × 52 cores = 104 total.
  def node_total_cpus(:fritz, "spr1tb"), do: 104
  def node_total_cpus(:fritz, "spr2tb"), do: 104

  # Fritz fallback (default partition is singlenode).
  def node_total_cpus(:fritz, _partition), do: 72

  # Unknown cluster: conservative fallback.
  def node_total_cpus(_cluster, _partition), do: 128

  # ── helpers ───────────────────────────────────────────────────────────────
  defp half_cpus(total), do: max(div(total, 2), 1)

  defp atom_value(opts, key, env_suffix, default, allowed) do
    value = Keyword.get(opts, key) || env_value(env_suffix, opts)

    case normalize_atom(value, allowed) do
      nil -> default
      atom -> atom
    end
  end

  defp atom_or_string_value(opts, key, env_suffix, default) do
    Keyword.get(opts, key) || env_value(env_suffix, opts) || default
  end

  defp string_value(opts, key, env_suffix, default) do
    case Keyword.get(opts, key) || env_value(env_suffix, opts) do
      nil -> default
      "" -> default
      value -> to_string(value)
    end
  end

  defp optional_string_value(opts, key, env_suffix, default \\ nil) do
    case Keyword.get(opts, key) || env_value(env_suffix, opts) do
      nil -> default
      "" -> default
      value -> to_string(value)
    end
  end

  defp bool_value(opts, key, env_suffix, default) do
    case Keyword.get(opts, key) do
      nil -> parse_bool(env_value(env_suffix, opts), default)
      value -> parse_bool(value, default)
    end
  end

  defp int_value(opts, key, env_suffix, default) do
    case int_from_opt(opts, key) || parse_int(env_value(env_suffix, opts)) do
      nil -> default
      value -> max(value, 1)
    end
  end

  # Like int_value/4 but allows nil (no limit) as a valid default.
  defp optional_int_value(opts, key, env_suffix, default) do
    case int_from_opt(opts, key) || parse_int(env_value(env_suffix, opts)) do
      nil -> default
      value -> max(value, 1)
    end
  end

  defp int_from_opt(opts, key), do: parse_int(Keyword.get(opts, key))

  defp env_value(suffix, opts), do: RootConfig.get("ATP_BENCHMARK_RUNNER_HPC_" <> suffix, opts)

  defp parse_bool(value, default)
  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when value in [true, false], do: value

  defp parse_bool(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      value when value in ["1", "true", "yes", "on"] -> true
      value when value in ["0", "false", "no", "off"] -> false
      _ -> default
    end
  end

  defp parse_bool(_value, default), do: default

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp normalize_atom(nil, _allowed), do: nil

  defp normalize_atom(value, allowed) when is_atom(value),
    do: if(value in allowed, do: value, else: nil)

  defp normalize_atom(value, allowed) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.find(allowed, fn atom -> Atom.to_string(atom) == normalized end)
  end

  defp normalize_atom(_value, _allowed), do: nil

  defp posix_join(left, right) do
    [String.trim_trailing(to_string(left), "/"), String.trim_leading(to_string(right), "/")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end
end
