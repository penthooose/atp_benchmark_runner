defmodule AtpBenchmarkRunner.InputTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.{Input, Problem, Prover}

  setup do
    dir = Path.join(System.tmp_dir!(), "atp_input_#{System.unique_integer([:positive])}")
    out = Path.join(dir, "out")
    File.mkdir_p!(out)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, out: out}
  end

  describe "THF problems (the reported defect)" do
    test "reach a THF prover untouched, with no conversion file written", %{out: out} do
      path = thf_problem(out)
      source = File.read!(path)

      for prover <- [:shot_tx, :lash] do
        assert {:ok, %{kind: :native, path: ^path}} =
                 Input.prepare(prover, problem(path), output_dir: out)

        assert File.read!(path) == source

        refute path |> Path.dirname() |> Path.join("THF000+0_thf.p") |> File.exists?()
      end
    end

    test "keep their lambda and application syntax" do
      path = thf_problem(Path.join(System.tmp_dir!(), "atp_thf_keep"))

      assert {:ok, %{path: path}} =
               Input.prepare(:shot_tx, problem(path), output_dir: path |> Path.dirname())

      content = File.read!(path)
      assert content =~ "@"
      assert content =~ "^"
      assert content =~ "! [P: $o]"
    end
  end

  describe "conversion (only when the prover needs it)" do
    test "FOF/CNF is converted to THF for a THF prover", %{out: out} do
      path = cnf_problem(out)

      assert {:ok, %{kind: :thf, path: converted}} =
               Input.prepare(:shot_tx, problem(path), output_dir: out)

      assert String.ends_with?(converted, "_thf.p")
      content = File.read!(converted)
      assert content =~ "thf("
      # Lash's quirk (negating a negated conjecture) stays inside the converter.
      refute content =~ "negated_conjecture"
      assert content =~ "conjecture"
    end

    test "a THF problem is not converted for a prover that cannot read THF", %{out: out} do
      path = thf_problem(out)

      assert {:skip, skip} = Input.prepare(:cvc5, problem(path), output_dir: out)
      assert skip.status == "InputError"
      assert skip.reason =~ "CVC5 does not support TH0 input"
      assert skip.reason =~ "converts: FOF, CNF"
    end

    test "invalid TPTP is rejected before any conversion runs", %{out: out} do
      # A lambda is THF syntax; inside `fof` the problem is not valid TPTP, and
      # the library rejects it instead of the converter silently dropping it.
      path =
        write(out, "GRA010+0.p", """
        %----
        % Status   : Theorem
        %----
        fof(a, axiom, p).
        fof(b, axiom, (^[X: $i]: (q(X))) @ c).
        """)

      assert {:skip, skip} = Input.prepare(:cvc5, problem(path), output_dir: out)
      assert skip.status == "InputError"
      assert skip.reason =~ "not valid TPTP"
      assert {:invalid_problem, [_ | _]} = skip.detail
    end

    test "the conversion gate counts the statements the converter must keep" do
      source = "fof(a, axiom, p).\nfof(b, axiom, p ~).\n"

      assert %{declared: 2, parsed: 1} =
               AtpBenchmarkRunner.TPTPToSMT.conversion_counts(source)
    end

    test "two same-named problems do not overwrite each other's conversion", %{dir: dir, out: out} do
      first = write(Path.join(dir, "first"), "GRP000-0.p", cnf_source())
      second = write(Path.join(dir, "second"), "GRP000-0.p", cnf_source())

      assert {:ok, %{path: a}} = Input.prepare(:shot_tx, problem(first), output_dir: out)
      assert {:ok, %{path: b}} = Input.prepare(:shot_tx, problem(second), output_dir: out)

      refute a == b
      assert File.exists?(a)
      assert File.exists?(b)
    end
  end

  describe "includes" do
    test "are expanded before the prover sees the problem", %{dir: dir, out: out} do
      File.mkdir_p!(Path.join(dir, "Axioms"))

      File.write!(
        Path.join(dir, "Axioms/GRA100+0.ax"),
        "fof(ax, axiom, shared_axiom).\n"
      )

      path =
        write(out, "GRA100+0.p", """
        %----
        % Status   : Satisfiable
        % SPC      : FOF_SAT_RFO_SEQ
        %----
        include('Axioms/GRA100+0.ax').
        fof(a, axiom, p).
        """)

      assert {:ok, %{kind: :expanded, path: expanded}} =
               Input.prepare(:vampire, problem(path), output_dir: out, tptp_root: dir)

      content = File.read!(expanded)
      assert content =~ "shared_axiom"
      refute content =~ "include("
      assert content =~ "fof(a, axiom, p)"
    end

    test "an unresolvable include is an input error, not a run", %{out: out} do
      path =
        write(out, "GRA101+0.p", """
        include('Axioms/MISSING+0.ax').
        fof(a, axiom, p).
        """)

      assert {:skip, skip} =
               Input.prepare(:vampire, problem(path), output_dir: out, tptp_root: out)

      assert skip.status == "InputError"
      assert skip.reason =~ "include directives could not be resolved"
    end

    test "a THF problem with includes is expanded but not rewritten", %{dir: dir, out: out} do
      File.mkdir_p!(Path.join(dir, "Axioms"))

      File.write!(
        Path.join(dir, "Axioms/THF_AX.ax"),
        "thf(ax_apply, axiom, ![P: $o > $o]: ( P @ $true )).\n"
      )

      path =
        write(out, "THF100+0.p", """
        %----
        % Status   : Theorem
        % SPC      : TH0_THM_EQU_NAR
        %----
        include('Axioms/THF_AX.ax').
        thf(goal, conjecture, (^[P: $o > $o]: (P @ $true)) = (^[P: $o > $o]: (P @ $true))).
        """)

      assert {:ok, %{kind: :expanded, path: expanded}} =
               Input.prepare(:shot_tx, problem(path), output_dir: out, tptp_root: dir)

      content = File.read!(expanded)

      # Expanded: the axiom set is inlined.
      assert content =~ "ax_apply"
      refute content =~ "include("

      # Untouched THF: application and lambda survive, nothing is renamed to the
      # Lash flavour and no negated conjecture is introduced.
      assert content =~ "@"
      assert content =~ "^"
      refute content =~ "negated_conjecture"
    end
  end

  describe "unusable input" do
    test "a missing file is reported as an input error", %{out: out} do
      missing = Path.join(out, "nope.p")
      problem = Problem.new(%{id: "nope", name: "nope", path: missing})

      assert {:skip, skip} = Input.prepare(:vampire, problem, output_dir: out)
      assert skip.status == "InputError"
      assert skip.reason =~ "could not be read"
    end
  end

  describe "plan/3" do
    test "decides every pair once and records skips", %{out: out} do
      thf = thf_problem(out)
      cnf = cnf_problem(out)

      plan =
        Input.plan(
          [:shot_tx, :lash, :cvc5],
          [problem(thf), problem(cnf)],
          output_dir: out
        )

      assert length(plan.entries) == 5
      assert length(plan.skips) == 1
      assert [%{prover: :cvc5, status: "InputError"}] = plan.skips

      assert {:ok, %{kind: :native}} = Map.fetch!(plan.inputs, "shot_tx|THF000+0")
      assert {:ok, %{kind: :native}} = Map.fetch!(plan.inputs, "lash|THF000+0")
      assert {:skip, _} = Map.fetch!(plan.inputs, "cvc5|THF000+0")
      assert {:ok, %{kind: :thf}} = Map.fetch!(plan.inputs, "shot_tx|GRP000-0")
    end

    test "skips become InputError results excluded from solve counts", %{out: out} do
      plan = Input.plan([:cvc5], [problem(thf_problem(out))], output_dir: out)

      assert [result] = Input.skipped_results(plan)
      assert result.szs_status == "InputError"
      assert result.prover == :cvc5
      assert result.metadata.reason =~ "CVC5"
      refute AtpBenchmarkRunner.Result.solved?(result)
    end
  end

  defp problem(path), do: Problem.from_tptp_file(path)

  defp thf_problem(dir) do
    write(dir, "THF000+0.p", """
    %----
    % Status   : Theorem
    % SPC      : TH0_THM_EQU_NAR
    %----
    thf(p_type, type, p: $o > $o).
    thf(lam, axiom, (^[P: $o > $o]: (P @ p)) = (^[P: $o > $o]: (P @ p))).
    thf(goal, conjecture, ! [P: $o] : ( ( P & P ) <=> P )).
    """)
  end

  defp cnf_problem(dir) do
    write(dir, "GRP000-0.p", cnf_source())
  end

  defp cnf_source do
    """
    %----
    % Status   : Unsatisfiable
    % SPC      : CNF_UNS_RFO_NEQ_HRN
    %----
    cnf(a, axiom, p).
    cnf(b, negated_conjecture, ~ p).
    """
  end

  defp write(dir, name, content) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  # Guards against a prover spec losing its dialect declaration: a THF prover
  # that accepts nothing would convert every THF problem again.
  test "THF provers declare the dialect they accept" do
    assert Prover.builtin!(:shot_tx).accepts == [:thf]
    assert Prover.builtin!(:lash).accepts == [:thf]
    assert Prover.builtin!(:vampire).accepts == :all
    assert Prover.builtin!(:cvc5).accepts == []
  end
end
