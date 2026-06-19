defmodule AtpBenchmarkRunner.Store do
  @moduledoc """
  Portable JSON persistence for benchmark manifests and reports.

  The first implementation deliberately uses plain files instead of a database so
  it works from Windows, Linux, and hosted Livebook runtimes. A SQLite backend can
  be added later without changing the domain structs.
  """

  alias AtpBenchmarkRunner.{Result, Run}
  alias AtpBenchmarkRunner.Store.LocalDb

  @doc """
  Returns the configured cache/store directory.
  """
  @spec default_dir() :: binary()
  def default_dir do
    System.get_env("ATP_BENCHMARK_RUNNER_CACHE_DIR") ||
      Application.get_env(:atp_benchmark_runner, :store_dir) ||
      Path.expand("./tmp/atp_benchmark_runner_store")
  end

  @doc """
  Saves a run manifest and returns the written path.
  """
  @spec save_run!(Run.t(), keyword()) :: binary()
  def save_run!(%Run{} = run, opts \\ []) do
    dir = ensure_dir!(Keyword.get(opts, :dir, default_dir()))
    path = Path.join(dir, "#{safe_name(run.id)}.run.json")
    write_json!(path, %{run: Run.to_map(run), metadata: artifact_metadata(run, opts)})
    maybe_put_run_db!(run, opts)
    path
  end

  @doc """
  Loads a previously saved run manifest.
  """
  @spec load_run!(binary()) :: Run.t()
  def load_run!(path) do
    path
    |> read_json!()
    |> Map.fetch!("run")
    |> Run.from_map()
  end

  @doc """
  Saves parsed run results with reproducibility metadata.
  """
  @spec save_results!(Run.t(), [Result.t() | map()], keyword()) :: binary()
  def save_results!(%Run{} = run, results, opts \\ []) when is_list(results) do
    dir = ensure_dir!(Keyword.get(opts, :dir, default_dir()))
    path = Path.join(dir, "#{safe_name(run.id)}.results.json")

    payload = %{
      run_id: run.id,
      metadata: artifact_metadata(run, opts),
      results: Enum.map(results, &result_to_map/1)
    }

    write_json!(path, payload)
    maybe_put_results_db!(run, results, opts)
    path
  end

  @doc """
  Loads parsed results from a saved result artifact.
  """
  @spec load_results!(binary()) :: [Result.t()]
  def load_results!(path) do
    path
    |> read_json!()
    |> Map.fetch!("results")
    |> Enum.map(&Result.from_map/1)
  end

  @doc """
  Saves a report with reproducibility metadata.
  """
  @spec save_report!(Run.t(), map(), keyword()) :: binary()
  def save_report!(%Run{} = run, report, opts \\ []) when is_map(report) do
    dir = ensure_dir!(Keyword.get(opts, :dir, default_dir()))
    path = Path.join(dir, "#{safe_name(run.id)}.report.json")
    write_json!(path, %{run_id: run.id, metadata: artifact_metadata(run, opts), report: report})
    maybe_put_report_db!(run, report, opts)
    path
  end

  @doc """
  Stores run, result, and report records in the local lightweight DB.
  """
  @spec save_to_db!(Run.t(), [Result.t() | map()], map(), keyword()) :: map()
  def save_to_db!(%Run{} = run, results, report, opts \\ []) when is_list(results) do
    LocalDb.put_run_results_report!(run, results, report, opts)
  end

  @doc """
  Lists normalized run records from the local lightweight DB.
  """
  @spec list_db_runs(keyword()) :: [map()]
  def list_db_runs(opts \\ []), do: LocalDb.list_runs(opts)

  @doc """
  Loads normalized result records from the local lightweight DB for one run.
  """
  @spec load_db_results!(binary(), keyword()) :: [map()]
  def load_db_results!(run_id, opts \\ []), do: LocalDb.load_results!(run_id, opts)

  @doc """
  Loads a stored report record from the local lightweight DB.
  """
  @spec load_db_report(binary(), keyword()) :: map() | nil
  def load_db_report(run_id, opts \\ []), do: LocalDb.load_report(run_id, opts)

  @doc """
  Saves an arbitrary report/snapshot and returns the written path.
  """
  @spec save_snapshot!(binary(), map(), keyword()) :: binary()
  def save_snapshot!(name, snapshot, opts \\ []) when is_map(snapshot) do
    dir = ensure_dir!(Keyword.get(opts, :dir, default_dir()))
    path = Path.join(dir, "#{safe_name(name)}.snapshot.json")
    write_json!(path, snapshot)
  end

  @doc """
  Lists saved run manifests, newest first.
  """
  @spec list_runs(keyword()) :: [binary()]
  def list_runs(opts \\ []) do
    dir = Keyword.get(opts, :dir, default_dir())

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".run.json"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  @doc """
  Appends an event to a JSON-lines recovery log.
  """
  @spec append_event!(binary(), map(), keyword()) :: binary()
  def append_event!(run_id, event, opts \\ []) when is_map(event) do
    dir = ensure_dir!(Keyword.get(opts, :dir, default_dir()))
    path = Path.join(dir, "#{safe_name(run_id)}.events.jsonl")
    encoded = Jason.encode!(Map.put_new(event, :at, DateTime.utc_now() |> DateTime.to_iso8601()))
    File.write!(path, encoded <> "\n", [:append])
    path
  end

  defp ensure_dir!(dir) do
    File.mkdir_p!(dir)
    dir
  end

  defp write_json!(path, data) do
    File.write!(path, Jason.encode!(data, pretty: true))
    path
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp result_to_map(%Result{} = result), do: Result.to_map(result)
  defp result_to_map(result) when is_map(result), do: result

  defp maybe_put_run_db!(%Run{} = run, opts) do
    if db_enabled?(opts), do: LocalDb.put_run!(run, opts)
  end

  defp maybe_put_results_db!(%Run{} = run, results, opts) do
    if db_enabled?(opts), do: LocalDb.put_results!(run, results, opts)
  end

  defp maybe_put_report_db!(%Run{} = run, report, opts) do
    if db_enabled?(opts), do: LocalDb.put_report!(run, report, opts)
  end

  defp db_enabled?(opts),
    do: Keyword.get(opts, :db?, false) or Keyword.get(opts, :backend) in [:local_db, :dets]

  defp artifact_metadata(%Run{} = run, opts) do
    %{
      saved_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      git_commit:
        Keyword.get(opts, :git_commit) || git_commit(Keyword.get(opts, :git_dir, File.cwd!())),
      config_snapshot: Keyword.get(opts, :config_snapshot, default_config_snapshot()),
      run_metadata: run.metadata
    }
  end

  defp default_config_snapshot do
    %{
      store_dir: default_dir(),
      tptp_dir: System.get_env("ATP_BENCHMARK_RUNNER_TPTP_DIR"),
      hpc_work_dir: System.get_env("HPC_CONNECT_WORK_DIR"),
      hpc_vault_dir: System.get_env("HPC_CONNECT_VAULT_DIR")
    }
  end

  defp git_commit(dir) do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: dir, stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
  end
end
