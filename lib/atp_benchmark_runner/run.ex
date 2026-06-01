defmodule AtpBenchmarkRunner.Run do
  @moduledoc """
  Immutable benchmark run configuration and manifest data.
  """

  alias AtpBenchmarkRunner.{Problem, Prover}

  @enforce_keys [:id, :problems, :provers]
  defstruct [
    :id,
    :title,
    :cluster,
    :partition,
    :remote_root,
    :inserted_at,
    :updated_at,
    status: :draft,
    walltime: "02:00:00",
    problem_timeout_seconds: 300,
    max_parallel_jobs: 32,
    problems: [],
    provers: [],
    submitted_jobs: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          title: binary() | nil,
          cluster: atom() | binary() | nil,
          partition: binary() | nil,
          remote_root: binary() | nil,
          status: :draft | :submitted | :running | :completed | :failed | :cancelled,
          walltime: binary(),
          problem_timeout_seconds: pos_integer(),
          max_parallel_jobs: pos_integer(),
          problems: [Problem.t()],
          provers: [Prover.t()],
          submitted_jobs: map(),
          metadata: map(),
          inserted_at: binary() | nil,
          updated_at: binary() | nil
        }

  @doc """
  Creates a benchmark run from options.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ [])
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    problems = attrs |> Map.get(:problems, []) |> Enum.map(&normalize_problem/1)

    provers =
      attrs
      |> Map.get(:provers, [:tableaux, :vampire, :eprover, :cvc5])
      |> Enum.map(&Prover.normalize/1)

    %__MODULE__{
      id: Map.get(attrs, :id) || generated_id(),
      title: Map.get(attrs, :title),
      cluster: Map.get(attrs, :cluster),
      partition: Map.get(attrs, :partition),
      remote_root: Map.get(attrs, :remote_root),
      status: attrs |> Map.get(:status, :draft) |> normalize_status(),
      walltime: Map.get(attrs, :walltime, "02:00:00"),
      problem_timeout_seconds: Map.get(attrs, :problem_timeout_seconds, 300),
      max_parallel_jobs: Map.get(attrs, :max_parallel_jobs, 32),
      problems: problems,
      provers: provers,
      submitted_jobs: Map.get(attrs, :submitted_jobs, %{}),
      metadata: Map.get(attrs, :metadata, %{}),
      inserted_at: Map.get(attrs, :inserted_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end

  @doc """
  Marks a run as submitted and records SLURM job metadata by prover name.
  """
  @spec mark_submitted(t(), map()) :: t()
  def mark_submitted(%__MODULE__{} = run, submitted_jobs) when is_map(submitted_jobs) do
    %{run | status: :submitted, submitted_jobs: submitted_jobs, updated_at: timestamp()}
  end

  @doc """
  Returns the run as a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = run) do
    %{
      id: run.id,
      title: run.title,
      cluster: run.cluster,
      partition: run.partition,
      remote_root: run.remote_root,
      status: run.status,
      walltime: run.walltime,
      problem_timeout_seconds: run.problem_timeout_seconds,
      max_parallel_jobs: run.max_parallel_jobs,
      problems: Enum.map(run.problems, &Problem.to_map/1),
      provers: Enum.map(run.provers, &Prover.to_map/1),
      submitted_jobs: run.submitted_jobs,
      metadata: run.metadata,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    map
    |> Map.update(:problems, [], &Enum.map(&1, fn problem -> Problem.from_map(problem) end))
    |> Map.update(:provers, [], &Enum.map(&1, fn prover -> Prover.from_map(prover) end))
    |> new()
  end

  defp normalize_problem(%Problem{} = problem), do: problem
  defp normalize_problem(path) when is_binary(path), do: Problem.from_path(path)
  defp normalize_problem(attrs), do: Problem.new(attrs)

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("draft"), do: :draft
  defp normalize_status("submitted"), do: :submitted
  defp normalize_status("running"), do: :running
  defp normalize_status("completed"), do: :completed
  defp normalize_status("failed"), do: :failed
  defp normalize_status("cancelled"), do: :cancelled
  defp normalize_status(_), do: :draft

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp generated_id do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    suffix = System.unique_integer([:positive])
    "run_#{stamp}_#{suffix}"
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> put_known_key(acc, key, value)
    end)
  end

  defp put_known_key(acc, key, value) do
    case key do
      "id" -> Map.put(acc, :id, value)
      "title" -> Map.put(acc, :title, value)
      "cluster" -> Map.put(acc, :cluster, value)
      "partition" -> Map.put(acc, :partition, value)
      "remote_root" -> Map.put(acc, :remote_root, value)
      "status" -> Map.put(acc, :status, value)
      "walltime" -> Map.put(acc, :walltime, value)
      "problem_timeout_seconds" -> Map.put(acc, :problem_timeout_seconds, value)
      "max_parallel_jobs" -> Map.put(acc, :max_parallel_jobs, value)
      "problems" -> Map.put(acc, :problems, value)
      "provers" -> Map.put(acc, :provers, value)
      "submitted_jobs" -> Map.put(acc, :submitted_jobs, value)
      "metadata" -> Map.put(acc, :metadata, value)
      "inserted_at" -> Map.put(acc, :inserted_at, value)
      "updated_at" -> Map.put(acc, :updated_at, value)
      _unknown -> acc
    end
  end
end
