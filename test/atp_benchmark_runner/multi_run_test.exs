defmodule AtpBenchmarkRunner.MultiRunTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.{MultiRun, Result}

  defp result(problem, prover, status, time_ms) do
    Result.new(%{
      problem_id: problem,
      prover: prover,
      szs_status: status,
      wall_time_ms: time_ms
    })
  end

  defp run(run_id, results) do
    %{run_id: run_id, saved_at: nil, path: nil, results: results}
  end

  describe "stats/2 aggregation" do
    test "aggregates min/max/best times across runs per (problem, prover)" do
      runs = [
        run("r1", [
          result("P1", :eprover, "Theorem", 100),
          result("P2", :eprover, "Timeout", 30_000)
        ]),
        run("r2", [
          result("P1", :eprover, "Theorem", 150),
          result("P1", :vampire, "Theorem", 90)
        ])
      ]

      stats = MultiRun.stats(runs)

      p1_eprover = cell(stats, "P1", :eprover)
      p1_vampire = cell(stats, "P1", :vampire)
      p2_eprover = cell(stats, "P2", :eprover)

      assert p1_eprover.solved
      assert p1_eprover.best_ms == 100
      assert p1_eprover.min_ms == 100
      assert p1_eprover.max_ms == 150
      assert p1_eprover.n_runs == 2

      assert p1_vampire.solved
      assert p1_vampire.best_ms == 90

      refute p2_eprover.solved
      assert p2_eprover.status == "Timeout"
    end

    test "per_prover ranking by solved problems" do
      runs = [
        run("r1", [
          result("P1", :eprover, "Theorem", 100),
          result("P2", :eprover, "Theorem", 100),
          result("P3", :eprover, "Timeout", 30_000),
          result("P1", :vampire, "Theorem", 50),
          result("P2", :vampire, "Timeout", 30_000)
        ])
      ]

      stats = MultiRun.stats(runs)

      eprover = Enum.find(stats.ranking, &(&1.prover == :eprover))
      vampire = Enum.find(stats.ranking, &(&1.prover == :vampire))

      assert eprover.attempted == 3
      assert eprover.solved == 2
      assert eprover.solve_rate == 2 / 3

      # Timeout counts as an attempt but not a solve.
      assert vampire.attempted == 2
      assert vampire.solved == 1

      # Best prover first.
      assert hd(stats.ranking).prover == :eprover
    end

    test "excludes input/type errors from attempts by default" do
      runs = [
        run("r1", [
          result("P1", :eprover, "Theorem", 100),
          result("P2", :eprover, "InputError", 0),
          result("P2", :vampire, "Theorem", 80)
        ])
      ]

      stats = MultiRun.stats(runs)
      eprover = Enum.find(stats.ranking, &(&1.prover == :eprover))

      # P2 InputError is not counted as an attempt.
      assert eprover.attempted == 1
      assert eprover.solved == 1
      assert eprover.solve_rate == 1.0

      # Explicit include option keeps them as attempts.
      stats_all = MultiRun.stats(runs, exclude_statuses: [])
      eprover_all = Enum.find(stats_all.ranking, &(&1.prover == :eprover))
      assert eprover_all.attempted == 2
      assert eprover_all.solved == 1
    end

    test "only_common_problems ranks on the shared problem set" do
      runs = [
        run("r1", [
          result("P1", :eprover, "Theorem", 100),
          result("P2", :eprover, "Theorem", 100),
          result("P3", :eprover, "Theorem", 100),
          result("P1", :vampire, "Theorem", 50),
          result("P2", :vampire, "InputError", 0)
        ])
      ]

      stats = MultiRun.stats(runs, only_common_problems: true)
      eprover = Enum.find(stats.ranking, &(&1.prover == :eprover))
      vampire = Enum.find(stats.ranking, &(&1.prover == :vampire))

      # Common set = problems both provers attempted (P1, P2).
      assert eprover.attempted == 2
      assert eprover.solved == 2
      assert vampire.attempted == 2
      assert vampire.solved == 1
    end
  end

  describe "markdown/2 rendering" do
    test "renders all three tables" do
      runs = [
        run("r1", [
          result("P1", :eprover, "Theorem", 100),
          result("P1", :vampire, "Timeout", 30_000)
        ])
      ]

      md = MultiRun.markdown(MultiRun.stats(runs))

      assert md =~ "# Cross-run benchmark comparison"
      assert md =~ "## Prover ranking"
      assert md =~ "## Per-problem × prover — best time & status"
      assert md =~ "## Per-problem × prover — time range"
      assert md =~ "✅ 100ms"
      assert md =~ "| P1 |"
      assert md =~ "r1"
    end
  end

  describe "save!/2" do
    test "writes the markdown to a file" do
      dir = Path.join(System.tmp_dir!(), "atp_multi_run_#{System.unique_integer([:positive])}")
      path = Path.join(dir, "comparison.md")
      stats = MultiRun.stats([])

      assert MultiRun.save!(path, stats) == path
      assert File.exists?(path)
      assert File.read!(path) =~ "# Cross-run benchmark comparison"
    end
  end

  defp cell(stats, problem, prover) do
    stats.per_problem
    |> Enum.find(&(&1.problem_id == problem))
    |> Map.fetch!(:provers)
    |> Map.fetch!(prover)
  end
end
