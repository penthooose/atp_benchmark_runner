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

    %{
      cluster: atom_or_string_value(opts, :cluster, "CLUSTER", session.cluster.name),
      node_kind: string_value(opts, :node_kind, "NODE_KIND", "cpu"),
      partition: string_value(opts, :partition, "PARTITION", "cpu"),
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
          default_cpus(hpc_mode, single_node_mode, max_parallel_jobs, prover_count)
        ),
      ntasks: int_value(opts, :ntasks, "NTASKS", 1),
      nodes: int_value(opts, :nodes, "NODES", default_nodes(hpc_mode)),
      gres: optional_string_value(opts, :gres, "GRES"),
      constraint: optional_string_value(opts, :constraint, "CONSTRAINT"),
      mem: optional_string_value(opts, :mem, "MEM"),
      exclusive:
        bool_value(
          opts,
          :exclusive,
          "EXCLUSIVE",
          default_exclusive(hpc_mode, single_node_mode)
        ),
      prepare_images: bool_value(opts, :prepare_images, "PREPARE_IMAGES", false),
      wait_for_completion: bool_value(opts, :wait_for_completion, "WAIT_FOR_COMPLETION", true),
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
          posix_join(session.vault_dir || session.work_dir, "tptp")
        )
    }
  end

  @spec terminal_state?(binary() | nil) :: boolean()
  def terminal_state?(state) when is_binary(state) do
    normalized = state |> String.trim() |> String.split([" ", "+"], parts: 2) |> hd()
    MapSet.member?(@terminal_states, normalized)
  end

  def terminal_state?(_), do: false

  # Single-node sequential: tasks run one at a time, each gets all available CPUs.
  # Return nil so no --cpus-per-task is set; --exclusive gives the full node.
  defp default_cpus(:single_node, :sequential, _max_parallel_jobs, _prover_count), do: nil

  # Single-node parallel: tasks may run concurrently.  Each prover process
  # runs with OMP_NUM_THREADS=1 so 1 CPU per task is sufficient; --exclusive
  # ensures the full node is allocated and SLURM manages the sharing.
  # Dynamic CPU division (point 4) will refine this later.
  defp default_cpus(:single_node, :parallel, _max_parallel_jobs, _prover_count), do: 1

  # Multi-node: each prover gets its own exclusive node, no cpus-per-task limit.
  defp default_cpus(:multi_node, _single_node_mode, _max_parallel_jobs, _prover_count), do: nil

  # Single-node: 1 node shared by all provers.
  defp default_nodes(:single_node), do: 1

  # Multi-node: 1 node per prover — each job gets its own node.
  defp default_nodes(:multi_node), do: 1

  # Single-node sequential: exclusive access to maximise throughput per task.
  defp default_exclusive(:single_node, :sequential), do: true

  # Single-node parallel: exclusive to avoid interference from other cluster jobs.
  defp default_exclusive(:single_node, :parallel), do: true

  # Multi-node: each prover runs alone on its node.
  defp default_exclusive(:multi_node, _single_node_mode), do: true

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

  defp optional_string_value(opts, key, env_suffix) do
    case Keyword.get(opts, key) || env_value(env_suffix, opts) do
      nil -> nil
      "" -> nil
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
