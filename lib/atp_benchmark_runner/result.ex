defmodule AtpBenchmarkRunner.Result do
  @moduledoc """
  Parsed result of running one prover on one benchmark problem.
  """

  @solved_statuses MapSet.new(~w(
    Theorem Unsatisfiable Satisfiable CounterSatisfiable ContradictoryAxioms
    CounterTheorem Equivalent NotEquivalent
  ))

  @enforce_keys [:problem_id, :prover]
  defstruct [
    :run_id,
    :problem_id,
    :problem_name,
    :prover,
    :szs_status,
    :exit_status,
    :wall_time_ms,
    :memory_kb,
    :collected_at,
    :output_path,
    :raw_output,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          run_id: binary() | nil,
          problem_id: binary(),
          problem_name: binary() | nil,
          prover: atom(),
          szs_status: binary() | nil,
          exit_status: integer() | nil,
          wall_time_ms: non_neg_integer() | nil,
          memory_kb: non_neg_integer() | nil,
          collected_at: binary() | nil,
          output_path: binary() | nil,
          raw_output: binary() | nil,
          metadata: map()
        }

  @doc """
  Builds a result from attrs.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)

    %__MODULE__{
      run_id: Map.get(attrs, :run_id),
      problem_id: to_string(Map.fetch!(attrs, :problem_id)),
      problem_name: Map.get(attrs, :problem_name),
      prover: normalize_prover(Map.fetch!(attrs, :prover)),
      szs_status: Map.get(attrs, :szs_status),
      exit_status: Map.get(attrs, :exit_status),
      wall_time_ms: Map.get(attrs, :wall_time_ms),
      memory_kb: Map.get(attrs, :memory_kb),
      collected_at: Map.get(attrs, :collected_at),
      output_path: Map.get(attrs, :output_path),
      raw_output: Map.get(attrs, :raw_output),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Parses a prover stdout/stderr blob into a result.
  """
  @spec from_output(binary() | atom(), binary(), binary(), keyword()) :: t()
  def from_output(prover, problem_id, output, attrs \\ []) do
    attrs
    |> Keyword.put(:prover, prover)
    |> Keyword.put(:problem_id, problem_id)
    |> Keyword.put_new(:szs_status, parse_szs_status(output))
    |> Keyword.put_new(:raw_output, output)
    |> new()
  end

  @doc """
  Extracts the first SZS status from ATP output.
  """
  @spec parse_szs_status(binary()) :: binary() | nil
  def parse_szs_status(output) when is_binary(output) do
    case Regex.run(~r/(?:^|\n)\s*%?\s*SZS\s+status\s+([A-Za-z][A-Za-z0-9_]*)/i, output,
           capture: :all_but_first
         ) do
      [status] -> status
      _ -> nil
    end
  end

  @doc """
  Returns true for statuses that count as a successful solve in TPTP reporting.
  """
  @spec solved?(t() | binary() | nil) :: boolean()
  def solved?(%__MODULE__{szs_status: status}), do: solved?(status)
  def solved?(status) when is_binary(status), do: MapSet.member?(@solved_statuses, status)
  def solved?(_), do: false

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      run_id: result.run_id,
      problem_id: result.problem_id,
      problem_name: result.problem_name,
      prover: result.prover,
      szs_status: result.szs_status,
      exit_status: result.exit_status,
      wall_time_ms: result.wall_time_ms,
      memory_kb: result.memory_kb,
      collected_at: result.collected_at,
      output_path: result.output_path,
      raw_output: result.raw_output,
      metadata: result.metadata
    }
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(map), do: new(map)

  defp normalize_prover(prover) when is_atom(prover), do: prover

  defp normalize_prover(prover) when is_binary(prover) do
    case AtpBenchmarkRunner.Provers.fetch(prover) do
      {:ok, known} -> known.name
      :error -> String.to_existing_atom(prover)
    end
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> put_known_key(acc, key, value)
    end)
  end

  defp put_known_key(acc, key, value) do
    case key do
      "run_id" -> Map.put(acc, :run_id, value)
      "problem_id" -> Map.put(acc, :problem_id, value)
      "problem_name" -> Map.put(acc, :problem_name, value)
      "prover" -> Map.put(acc, :prover, value)
      "szs_status" -> Map.put(acc, :szs_status, value)
      "exit_status" -> Map.put(acc, :exit_status, value)
      "wall_time_ms" -> Map.put(acc, :wall_time_ms, value)
      "memory_kb" -> Map.put(acc, :memory_kb, value)
      "collected_at" -> Map.put(acc, :collected_at, value)
      "output_path" -> Map.put(acc, :output_path, value)
      "raw_output" -> Map.put(acc, :raw_output, value)
      "metadata" -> Map.put(acc, :metadata, value)
      _unknown -> acc
    end
  end
end
