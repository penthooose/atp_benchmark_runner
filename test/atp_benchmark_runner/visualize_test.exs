defmodule AtpBenchmarkRunner.VisualizeTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.{Result, Visualize}
  alias AtpBenchmarkRunner.Visualize.Proof

  defp result(attrs \\ []) do
    Result.new(
      Keyword.merge(
        [
          problem_id: "GRP001-0",
          problem_name: "GRP001-0.p",
          prover: :eprover,
          szs_status: "Theorem",
          wall_time_ms: 812,
          memory_kb: 12_345
        ],
        attrs
      )
    )
  end

  defp refutation_output do
    """
    % SZS status Theorem
    % SZS output start CNFRefutation
    fof(unit_not_a, axiom, ~(a), file('x', unit_not_a)).
    fof(unit_a, axiom, a, file('x', unit_a)).
    fof(c_0_2, plain, ~a, inference(fof_simplification,[status(thm)],[unit_not_a])).
    cnf(c_0_4, plain, (~a), inference(split_conjunct,[status(thm)],[c_0_2])).
    cnf(c_0_5, plain, (a), inference(split_conjunct,[status(thm)],[unit_a])).
    cnf(c_0_6, plain, ($false), inference(cn,[status(thm)],[inference(rw,[status(thm)],[c_0_4, c_0_5])]), ['proof']).
    % SZS output end CNFRefutation
    """
  end

  describe "Visualize.Proof" do
    test "parses an E-style CNF refutation into a dependency graph" do
      r = result(raw_output: refutation_output())

      assert {:ok, graph} = Proof.parse(r)
      assert length(graph.steps) == 6
      assert graph.root == "c_0_6"

      edges = graph.edges
      assert {"unit_not_a", "c_0_2"} in edges
      assert {"c_0_2", "c_0_4"} in edges
      assert {"c_0_4", "c_0_6"} in edges
      assert {"c_0_5", "c_0_6"} in edges
    end

    test "returns an error when the raw output has no proof block" do
      r = result()
      assert {:error, _} = Proof.parse(r)
    end

    test "returns an error for prose proofs without TPTP clause steps" do
      r =
        result(
          raw_output:
            "% SZS status Theorem\n% SZS output start Proof\nsome prose\n% SZS output end Proof"
        )

      assert {:error, _} = Proof.parse(r)
    end
  end

  describe "Visualize.result/1" do
    test "emits a mermaid flowchart with prover, problem, status and timing" do
      diagram = Visualize.result(result())

      assert diagram =~ "flowchart LR"
      assert diagram =~ "eprover"
      assert diagram =~ "GRP001-0"
      assert diagram =~ "✅ Solved"
      assert diagram =~ "Theorem"
      assert diagram =~ "812 ms"
      assert diagram =~ "12.1 MB"
    end

    test "uses the failed style for unsolved results" do
      diagram = Visualize.result(result(szs_status: "GaveUp"))
      assert diagram =~ "❌ Failed"
      assert diagram =~ "class P,B,S,T failed"
    end
  end

  describe "Visualize.proof/1" do
    test "renders a dependency DAG for a parseable refutation" do
      diagram = Visualize.proof(result(raw_output: refutation_output()))

      assert diagram =~ "flowchart LR"
      assert diagram =~ "n_unit_not_a"
      assert diagram =~ "n_unit_a"
      assert diagram =~ "n_c_0_6"
      assert diagram =~ "n_unit_not_a --> n_c_0_2"
      assert diagram =~ "n_c_0_4 --> n_c_0_6"
      assert diagram =~ "n_c_0_5 --> n_c_0_6"
      # the root step is highlighted via a class statement
      assert diagram =~ "class n_c_0_6 root"
    end

    test "degrades to a pipeline for non-graph proof formats" do
      r =
        result(
          raw_output:
            "% SZS status Theorem\n% SZS output start Proof\nsome prose proof\n% SZS output end Proof"
        )

      diagram = Visualize.proof(r)

      assert diagram =~ "flowchart LR"
      assert diagram =~ "GRP001-0"
      assert diagram =~ "non-graph format"
    end

    test "handles a result without a proof block" do
      diagram = Visualize.proof(result())

      assert diagram =~ "flowchart LR"
      assert diagram =~ "no proof block"
    end

    test "caps large proofs to max_nodes" do
      steps =
        Enum.map_join(1..80, "\n", fn i ->
          dep = if i > 1, do: "s#{i - 1}", else: "s1"
          "cnf(s#{i}, plain, (p#{i}), inference(rw,[status(thm)],[#{dep}]))"
        end)

      output = "% SZS output start CNFRefutation\n#{steps}\n% SZS output end CNFRefutation"
      diagram = Visualize.proof(result(raw_output: output), max_nodes: 10)

      assert diagram =~ "10 of 80 proof steps shown"
    end
  end

  describe "Visualize.status_pie/1" do
    test "groups results by SZS status" do
      rs = [
        result(szs_status: "Theorem"),
        result(szs_status: "Theorem", problem_id: "GRP002+0"),
        result(szs_status: "GaveUp", problem_id: "GRP003+0"),
        result(prover: :vampire, szs_status: "Theorem")
      ]

      pie = Visualize.status_pie(rs)

      assert pie =~ "pie showData"
      assert pie =~ "\"Theorem\" : 3"
      assert pie =~ "\"GaveUp\" : 1"
    end

    test "restricts to a single prover with the :prover option" do
      rs = [
        result(szs_status: "Theorem"),
        result(prover: :vampire, szs_status: "GaveUp")
      ]

      pie = Visualize.status_pie(rs, prover: :eprover)
      assert pie =~ "\"Theorem\" : 1"
      refute pie =~ "GaveUp"
    end
  end

  describe "Visualize.timeline/1" do
    test "emits a gantt with one section per problem" do
      rs = [
        result(wall_time_ms: 1000),
        result(problem_id: "GRP002+0", wall_time_ms: 2000)
      ]

      g = Visualize.timeline(rs)

      assert g =~ "gantt"
      assert g =~ "section GRP001-0"
      assert g =~ "section GRP002+0"
      assert g =~ "eprover : 0, 1"
      assert g =~ "eprover : 0, 2"
    end

    test "ignores missing wall times" do
      g = Visualize.timeline([result(wall_time_ms: nil)])
      assert g =~ "eprover : 0, 0"
    end
  end

  describe "Visualize.report/1" do
    test "emits a scoreboard flowchart" do
      report =
        AtpBenchmarkRunner.report([
          result(szs_status: "Theorem"),
          result(szs_status: "GaveUp", problem_id: "GRP002+0")
        ])

      d = Visualize.report(report)

      assert d =~ "flowchart LR"
      assert d =~ "Total: 2 results"
      assert d =~ "Solved: 1 (50.0%)"
      assert d =~ "eprover: 1/2 (50.0%)"
    end
  end

  describe "rendering" do
    test "markdown/1 wraps a diagram in a mermaid fence" do
      assert Visualize.markdown("graph TD\n  A-->B") == "```mermaid\ngraph TD\n  A-->B\n```\n"
    end

    test "render/1 falls back to a fenced block when Kino is not running" do
      # In the bare test env the Kino application is not started, so render
      # must produce a plain markdown block rather than a Kino struct.
      rendered = Visualize.render("graph TD\n  A-->B")

      if Visualize.available?() do
        assert is_struct(rendered)
      else
        assert rendered =~ "```mermaid"
      end
    end

    test "top-level visualize/1 dispatches on a single result" do
      rendered = AtpBenchmarkRunner.visualize(result())

      if Visualize.available?() do
        assert is_struct(rendered)
      else
        assert rendered =~ "flowchart LR"
      end
    end
  end
end
