defmodule AtpBenchmarkRunner.Scheduler do
  @moduledoc """
  Optional Oban integration boundary for nightly benchmark runs.

  This module has no hard compile-time dependency on Oban. Add and configure
  Oban/Postgres in the host application, then use `enqueue_nightly/2`.

  Because Oban jobs are JSON-serialized, real side effects are dispatched through
  a host-provided MFA descriptor, for example:

      %{
        "runner_mfa" => %{
          "module" => "MyApp.AtpNightly",
          "function" => "run",
          "args" => [%{"cluster" => "fritz"}]
        }
      }
  """

  @doc """
  Returns true when Oban is available at runtime.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Oban.Job)

  @doc """
  Returns a suggested Oban cron configuration for nightly runs.
  """
  @spec oban_config(keyword()) :: keyword()
  def oban_config(opts \\ []) do
    cron = Keyword.get(opts, :cron, "0 20 * * *")
    queue = Keyword.get(opts, :queue, :benchmarks)

    [
      queues: [{queue, Keyword.get(opts, :limit, 1)}],
      plugins: [{Oban.Plugins.Cron, crontab: [{cron, __MODULE__, args: default_args(opts)}]}]
    ]
  end

  @doc """
  Enqueues a nightly benchmark job when Oban is configured.
  """
  @spec enqueue_nightly(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def enqueue_nightly(args, opts \\ []) when is_map(args) do
    if available?() do
      job =
        apply(Oban.Job, :new, [
          stringify_keys(args),
          [worker: __MODULE__, queue: Keyword.get(opts, :queue, :benchmarks)]
        ])

      apply(Oban, :insert, [job])
    else
      {:error, :oban_not_available}
    end
  end

  @doc """
  Returns the canonical nightly job argument map for a host runner MFA.

  Pass the returned map to `enqueue_nightly/2` from a host application or
  schedule it through the `Oban.Plugins.Cron` configuration produced by
  `oban_config/1`. The runner MFA must accept a single argument (the same
  map) and return `:ok | {:ok, value} | {:error, reason}`.

      AtpBenchmarkRunner.Scheduler.runner_args(
        module: "MyApp.AtpNightly",
        function: "run",
        args: [%{"cluster" => "fritz"}],
        cluster: "fritz",
        provers: ["tableaux", "vampire", "eprover", "cvc5"]
      )
  """
  @spec runner_args(keyword()) :: map()
  def runner_args(opts \\ []) do
    %{
      "cluster" => Keyword.get(opts, :cluster, "fritz"),
      "provers" => Keyword.get(opts, :provers, ["tableaux", "vampire", "eprover", "cvc5"]),
      "problem_filter" => Keyword.get(opts, :problem_filter, %{}),
      "runner_mfa" => %{
        "module" => to_string(Keyword.get(opts, :module, "")),
        "function" => to_string(Keyword.get(opts, :function, "run")),
        "args" => Keyword.get(opts, :args, [])
      }
    }
  end

  @doc """
  Oban worker callback.

  The production worker can call host orchestration through `runner_mfa`. It is
  deliberately side-effect free when no runner is configured, so enabling the
  optional Oban dependency never submits cluster jobs accidentally.
  """
  @spec perform(term()) :: :ok | {:error, term()}
  def perform(job) do
    args = Map.get(job, :args) || Map.get(job, "args") || %{}

    cond do
      is_function(Map.get(args, "runner") || Map.get(args, :runner), 1) ->
        runner = Map.get(args, "runner") || Map.get(args, :runner)
        runner.(args)

      runner_mfa = Map.get(args, "runner_mfa") || Map.get(args, :runner_mfa) ->
        apply_runner_mfa(runner_mfa)

      true ->
        :ok
    end
  end

  defp apply_runner_mfa(mfa) when is_map(mfa) do
    with {:ok, module} <- existing_module(Map.get(mfa, "module") || Map.get(mfa, :module)),
         {:ok, function} <- existing_function(Map.get(mfa, "function") || Map.get(mfa, :function)),
         args when is_list(args) <- Map.get(mfa, "args") || Map.get(mfa, :args) || [],
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      false -> {:error, :runner_mfa_not_exported}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_runner_mfa}
    end
  end

  defp apply_runner_mfa(_), do: {:error, :invalid_runner_mfa}

  defp existing_module(module) when is_atom(module), do: {:ok, module}

  defp existing_module(module) when is_binary(module) do
    module_name = if String.starts_with?(module, "Elixir."), do: module, else: "Elixir." <> module
    {:ok, String.to_existing_atom(module_name)}
  rescue
    ArgumentError -> {:error, :unknown_runner_module}
  end

  defp existing_module(_), do: {:error, :invalid_runner_module}

  defp existing_function(function) when is_atom(function), do: {:ok, function}

  defp existing_function(function) when is_binary(function),
    do: {:ok, String.to_existing_atom(function)}

  defp existing_function(_), do: {:error, :invalid_runner_function}

  defp default_args(opts) do
    %{
      "cluster" => Keyword.get(opts, :cluster, "fritz"),
      "provers" => Keyword.get(opts, :provers, ["tableaux", "vampire", "eprover", "cvc5"]),
      "problem_filter" => Keyword.get(opts, :problem_filter, %{})
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
