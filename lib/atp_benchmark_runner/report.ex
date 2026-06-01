defmodule AtpBenchmarkRunner.Report do
  @moduledoc """
  Aggregates benchmark results into comparison-friendly summaries.
  """

  alias AtpBenchmarkRunner.{Problem, Result, Run}

  @doc """
  Builds a report map suitable for Livebook tables, Markdown, or JSON export.
  """
  @spec summarize([Result.t() | map()], Run.t() | nil, keyword()) :: map()
  def summarize(results, run \\ nil, opts \\ []) when is_list(results) do
    normalized = Enum.map(results, &normalize_result/1)
    problems = problem_index(run)
    our_prover = Keyword.get(opts, :our_prover, :tableaux)
    generated_at = Keyword.get(opts, :generated_at, timestamp())

    %{
      run_id: run_id(run, normalized),
      generated_at: generated_at,
      totals: totals(normalized),
      by_prover: by_prover(normalized),
      by_rating_bucket:
        by_rating_bucket(normalized, problems, Keyword.get(opts, :bucket_size, 0.1)),
      by_problem: by_problem(normalized),
      result_rows: result_rows(normalized, problems, run),
      interesting: interesting(normalized, problems, our_prover),
      markdown: markdown_summary(normalized, problems, our_prover)
    }
  end

  @doc """
  Converts a report to a concise Markdown summary.
  """
  @spec markdown_summary([Result.t()], map(), atom()) :: binary()
  def markdown_summary(results, problems \\ %{}, our_prover \\ :tableaux) do
    rows = by_prover(results)

    table =
      rows
      |> Enum.map_join("\n", fn row ->
        "| #{row.prover} | #{row.total} | #{row.solved} | #{Float.round(row.solve_rate * 100, 1)}% |"
      end)

    interesting = interesting(results, problems, our_prover)

    """
    ## ATP Benchmark Summary

    | Prover | Total | Solved | Solve rate |
    |---|---:|---:|---:|
    #{table}

    - Easy problems our prover failed: #{length(interesting.easy_failed_by_ours)}
    - Hard problems our prover solved: #{length(interesting.hard_solved_by_ours)}
    - Problems solved only by our prover: #{length(interesting.only_ours)}
    - Problems solved only by reference provers: #{length(interesting.only_others)}
    """
    |> String.trim()
  end

  defp totals(results) do
    total = length(results)
    solved = Enum.count(results, &Result.solved?/1)

    %{
      total_results: total,
      solved_results: solved,
      solve_rate: ratio(solved, total)
    }
  end

  defp by_prover(results) do
    results
    |> Enum.group_by(& &1.prover)
    |> Enum.map(fn {prover, prover_results} ->
      total = length(prover_results)
      solved = Enum.count(prover_results, &Result.solved?/1)

      %{
        prover: prover,
        total: total,
        solved: solved,
        failed: total - solved,
        solve_rate: ratio(solved, total),
        statuses: Enum.frequencies_by(prover_results, &(&1.szs_status || "Unknown"))
      }
    end)
    |> Enum.sort_by(& &1.prover)
  end

  defp by_problem(results) do
    results
    |> Enum.group_by(& &1.problem_id)
    |> Enum.map(fn {problem_id, problem_results} ->
      solved_by = problem_results |> Enum.filter(&Result.solved?/1) |> Enum.map(& &1.prover)

      %{
        problem_id: problem_id,
        attempts: length(problem_results),
        solved_by: solved_by,
        statuses: Map.new(problem_results, &{&1.prover, &1.szs_status || "Unknown"})
      }
    end)
    |> Enum.sort_by(& &1.problem_id)
  end

  defp result_rows(results, problems, run) do
    Enum.map(results, fn result ->
      problem = Map.get(problems, result.problem_id)

      %{
        run_id: result.run_id || run_id(run, [result]),
        run_inserted_at: if(run, do: run.inserted_at),
        collected_at: result.collected_at,
        problem_id: result.problem_id,
        problem_name: result.problem_name || problem_name(problem),
        rating: problem_rating(problems, result.problem_id),
        prover: result.prover,
        szs_status: result.szs_status || "Unknown",
        solved: Result.solved?(result),
        exit_status: result.exit_status,
        wall_time_ms: result.wall_time_ms,
        memory_kb: result.memory_kb,
        output_path: result.output_path
      }
    end)
  end

  defp by_rating_bucket(results, problems, bucket_size) do
    results
    |> Enum.group_by(& &1.prover)
    |> Enum.map(fn {prover, prover_results} ->
      buckets =
        prover_results
        |> Enum.group_by(fn result ->
          bucket_for(problem_rating(problems, result.problem_id), bucket_size)
        end)
        |> Enum.map(fn {bucket, bucket_results} ->
          total = length(bucket_results)
          solved = Enum.count(bucket_results, &Result.solved?/1)

          %{
            bucket: bucket,
            total: total,
            solved: solved,
            failed: total - solved,
            solve_rate: ratio(solved, total)
          }
        end)
        |> Enum.sort_by(& &1.bucket)

      %{prover: prover, buckets: buckets}
    end)
    |> Enum.sort_by(& &1.prover)
  end

  defp interesting(results, problems, our_prover) do
    problem_rows = by_problem(results)

    %{
      easy_failed_by_ours:
        Enum.filter(problem_rows, fn row ->
          easy?(problems[row.problem_id]) and our_prover not in row.solved_by
        end),
      hard_solved_by_ours:
        Enum.filter(problem_rows, fn row ->
          hard?(problems[row.problem_id]) and our_prover in row.solved_by
        end),
      only_ours: Enum.filter(problem_rows, fn row -> row.solved_by == [our_prover] end),
      only_others:
        Enum.filter(problem_rows, fn row ->
          row.solved_by != [] and our_prover not in row.solved_by
        end)
    }
  end

  defp problem_index(nil), do: %{}

  defp problem_index(%Run{} = run) do
    Map.new(run.problems, fn %Problem{} = problem -> {problem.id, problem} end)
  end

  defp run_id(%Run{id: id}, _results), do: id
  defp run_id(nil, [%Result{run_id: run_id} | _]) when is_binary(run_id), do: run_id
  defp run_id(_run, _results), do: nil

  defp problem_name(%Problem{name: name}), do: name
  defp problem_name(_), do: nil

  defp easy?(%Problem{rating: rating}) when is_number(rating), do: rating <= 0.0
  defp easy?(_), do: false

  defp hard?(%Problem{rating: rating}) when is_number(rating), do: rating >= 1.0
  defp hard?(_), do: false

  defp problem_rating(problems, problem_id) do
    case Map.get(problems, problem_id) do
      %Problem{rating: rating} when is_number(rating) -> rating
      _ -> nil
    end
  end

  defp bucket_for(nil, _bucket_size), do: "unknown"

  defp bucket_for(rating, bucket_size) do
    lower = Float.floor(rating / bucket_size) * bucket_size
    upper = min(lower + bucket_size, 1.0)
    "#{format_bucket_edge(lower)}-#{format_bucket_edge(upper)}"
  end

  defp format_bucket_edge(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp normalize_result(%Result{} = result), do: result
  defp normalize_result(result) when is_map(result), do: Result.from_map(result)

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, total), do: part / total

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
