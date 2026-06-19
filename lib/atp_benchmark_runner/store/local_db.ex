defmodule AtpBenchmarkRunner.Store.LocalDb do
  @moduledoc """
  Dependency-free local database for normalized benchmark records.

  The backend uses Erlang DETS so Livebook and local scripts can persist/query
  run/result/report records without adding SQLite or Postgres. SQLite can still
  be added later behind the same public shapes if we need richer ad-hoc SQL.
  """

  alias AtpBenchmarkRunner.{Report, Result, Run, Store}

  @base_table :atp_benchmark_runner_local_db
  @db_file "atp_benchmark_runner.dets"

  @doc """
  Unique DETS table name per database path.

  DETS uses a global name registry — same name, different file = silent
  cross-talk. We hash the path to keep tables isolated.
  """
  @spec table_name(binary()) :: atom()
  def table_name(db_path) when is_binary(db_path) do
    suffix =
      db_path
      |> Path.expand()
      |> then(&:erlang.md5(&1))
      |> Base.encode16(case: :lower)

    :"#{@base_table}_#{suffix}"
  end

  @doc """
  Returns the DETS database path for the given store options.
  """
  @spec path(keyword()) :: binary()
  def path(opts \\ []) do
    opts
    |> Keyword.get(:db_path, Path.join(Keyword.get(opts, :dir, Store.default_dir()), @db_file))
    |> Path.expand()
  end

  @doc """
  Stores a normalized run record.
  """
  @spec put_run!(Run.t(), keyword()) :: map()
  def put_run!(%Run{} = run, opts \\ []) do
    record = run_record(run)

    with_db(opts, fn table ->
      :ok = :dets.insert(table, {{:run, run.id}, record})
      record
    end)
  end

  @doc """
  Stores one normalized record per result attempt.
  """
  @spec put_results!(Run.t(), [Result.t() | map()], keyword()) :: [map()]
  def put_results!(%Run{} = run, results, opts \\ []) when is_list(results) do
    collected_at = Keyword.get(opts, :collected_at, timestamp())
    normalized = Enum.map(results, &normalize_result/1)
    records = Enum.map(normalized, &result_record(run, &1, collected_at))

    with_db(opts, fn table ->
      :ok = :dets.insert(table, {{:run, run.id}, run_record(run)})

      Enum.each(records, fn record ->
        key = {:result, record.run_id, Atom.to_string(record.prover), record.problem_id}
        :ok = :dets.insert(table, {key, record})
      end)

      records
    end)
  end

  @doc """
  Stores a report for a run.
  """
  @spec put_report!(Run.t(), map(), keyword()) :: map()
  def put_report!(%Run{} = run, report, opts \\ []) when is_map(report) do
    record = %{
      run_id: run.id,
      generated_at:
        Map.get(report, :generated_at) || Map.get(report, "generated_at") || timestamp(),
      report: report
    }

    with_db(opts, fn table ->
      :ok = :dets.insert(table, {{:report, run.id}, record})
      record
    end)
  end

  @doc """
  Stores run, results, and report records in one local DB transaction-like call.
  """
  @spec put_run_results_report!(Run.t(), [Result.t() | map()], map(), keyword()) :: map()
  def put_run_results_report!(%Run{} = run, results, report, opts \\ []) do
    %{
      run: put_run!(run, opts),
      results: put_results!(run, results, opts),
      report: put_report!(run, report, opts),
      db_path: path(opts)
    }
  end

  @doc """
  Lists stored run records, newest first.
  """
  @spec list_runs(keyword()) :: [map()]
  def list_runs(opts \\ []) do
    with_db(opts, fn table ->
      table
      |> fold_records(fn
        {{:run, _run_id}, record}, acc -> [record | acc]
        _other, acc -> acc
      end)
      |> Enum.sort_by(&Map.get(&1, :inserted_at, ""), :desc)
    end)
  end

  @doc """
  Loads normalized result records for one run.
  """
  @spec load_results!(binary(), keyword()) :: [map()]
  def load_results!(run_id, opts \\ []) when is_binary(run_id) do
    with_db(opts, fn table ->
      table
      |> fold_records(fn
        {{:result, ^run_id, _prover, _problem_id}, record}, acc -> [record | acc]
        _other, acc -> acc
      end)
      |> Enum.sort_by(&{Atom.to_string(&1.prover), &1.problem_id})
    end)
  end

  @doc """
  Loads the stored report record for a run, or `nil` when absent.
  """
  @spec load_report(binary(), keyword()) :: map() | nil
  def load_report(run_id, opts \\ []) when is_binary(run_id) do
    with_db(opts, fn table ->
      case :dets.lookup(table, {:report, run_id}) do
        [{_key, record}] -> record
        [] -> nil
      end
    end)
  end

  @doc """
  Builds a report from records stored for a run.
  """
  @spec report_from_run(binary(), Run.t() | nil, keyword()) :: map()
  def report_from_run(run_id, run \\ nil, opts \\ []) do
    run_id
    |> load_results!(opts)
    |> Enum.map(&Result.from_map/1)
    |> Report.summarize(run, opts)
  end

  defp with_db(opts, fun) when is_function(fun, 1) do
    db_path = path(opts)
    File.mkdir_p!(Path.dirname(db_path))
    table = table_name(db_path)

    case :dets.open_file(table, file: String.to_charlist(db_path), type: :set) do
      {:ok, ^table} ->
        try do
          fun.(table)
        after
          :dets.close(table)
        end

      {:error, {:already_started, _pid}} ->
        try do
          fun.(table)
        after
          :dets.close(table)
        end

      {:error, reason} ->
        raise "could not open ATP benchmark local DB #{db_path}: #{inspect(reason)}"
    end
  end

  defp fold_records(table, fun) do
    :dets.foldl(fun, [], table)
  end

  defp run_record(%Run{} = run) do
    run
    |> Run.to_map()
    |> Map.take([
      :id,
      :title,
      :cluster,
      :partition,
      :status,
      :inserted_at,
      :updated_at,
      :metadata
    ])
    |> Map.put(:problem_count, length(run.problems))
    |> Map.put(:provers, Enum.map(run.provers, & &1.name))
  end

  defp result_record(%Run{} = run, %Result{} = result, collected_at) do
    run_id = result.run_id || run.id
    collected_at = result.collected_at || collected_at

    %{
      run_id: run_id,
      run_inserted_at: run.inserted_at,
      collected_at: collected_at,
      problem_id: result.problem_id,
      problem_name: result.problem_name,
      prover: result.prover,
      szs_status: result.szs_status,
      solved: Result.solved?(result),
      exit_status: result.exit_status,
      wall_time_ms: result.wall_time_ms,
      memory_kb: result.memory_kb,
      output_path: result.output_path,
      metadata: result.metadata
    }
  end

  defp normalize_result(%Result{} = result), do: result
  defp normalize_result(result) when is_map(result), do: Result.from_map(result)

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
