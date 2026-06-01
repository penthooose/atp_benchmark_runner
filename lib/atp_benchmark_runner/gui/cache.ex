defmodule AtpBenchmarkRunner.GUI.Cache do
  @moduledoc """
  Livebook-friendly recovery cache.

  This is intentionally file-based rather than process-based. Livebook cells are
  often re-run, recompiled, or interrupted; a small JSON cache lets users recover
  the active run manifest and submitted job IDs without relying on a live process.
  """

  alias AtpBenchmarkRunner.{Run, Store}

  @doc """
  Returns the cache directory used by GUI helpers.
  """
  @spec cache_dir(keyword()) :: binary()
  def cache_dir(opts \\ []) do
    Keyword.get(opts, :cache_dir) ||
      System.get_env("LIVEBOOK_ATP_BENCHMARK_CACHE_DIR") ||
      Store.default_dir()
  end

  @doc """
  Saves the current run manifest for recovery.
  """
  @spec save_run!(Run.t(), keyword()) :: binary()
  def save_run!(%Run{} = run, opts \\ []) do
    Store.save_run!(run, dir: cache_dir(opts))
  end

  @doc """
  Saves a status/report snapshot for recovery.
  """
  @spec save_snapshot!(Run.t(), map(), keyword()) :: binary()
  def save_snapshot!(%Run{} = run, snapshot, opts \\ []) do
    Store.save_snapshot!(run.id, snapshot, dir: cache_dir(opts))
  end

  @doc """
  Records an event in a JSON-lines journal.
  """
  @spec record_event!(Run.t() | binary(), map(), keyword()) :: binary()
  def record_event!(run_or_id, event, opts \\ [])
  def record_event!(%Run{} = run, event, opts), do: record_event!(run.id, event, opts)

  def record_event!(run_id, event, opts) when is_binary(run_id) do
    Store.append_event!(run_id, event, dir: cache_dir(opts))
  end

  @doc """
  Loads the most recent cached run, if any.
  """
  @spec load_latest_run(keyword()) :: {:ok, Run.t()} | :error
  def load_latest_run(opts \\ []) do
    opts
    |> cache_dir()
    |> then(&Store.list_runs(dir: &1))
    |> List.first()
    |> case do
      nil -> :error
      path -> {:ok, Store.load_run!(path)}
    end
  end
end
