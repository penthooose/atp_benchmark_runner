defmodule AtpBenchmarkRunner.LocalRunnerTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.{LocalRunner, Problem, Prover, Result}

  describe "detect_available/0" do
    test "returns a map with known keys" do
      avail = LocalRunner.detect_available()
      assert Map.has_key?(avail, :tableaux)
      assert Map.has_key?(avail, :docker)
      assert Map.has_key?(avail, :docker_images)
      assert Map.has_key?(avail, :escript)
      assert Map.has_key?(avail, :on_path)
      assert is_list(avail.on_path)
      assert is_boolean(avail.docker)
      assert is_map(avail.docker_images)
    end
  end

  describe "run_single/3" do
    test "runs a tableaux prover against a problem and returns a result" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "atp_local_runner_#{System.unique_integer([:positive])}")

      [problem_path | _] =
        AtpBenchmarkRunner.install_tptp_examples!(root_dir: tmp_dir, force: true)

      problem = Problem.from_tptp_file(problem_path)

      result = LocalRunner.run_single(:tableaux, problem, timeout_seconds: 10)

      assert %Result{} = result
      assert result.problem_id == problem.id
      assert result.prover == :tableaux
    end

    test "returns GaveUp for unknown executables" do
      problem = Problem.new(%{id: "test", name: "test", path: "nonexistent.p"})

      result =
        LocalRunner.run_single(
          %Prover{
            name: :nonexistent_prover,
            label: "Nonexistent",
            command_template: "nonexistent_binary_xyz --input {problem}"
          },
          problem,
          timeout_seconds: 5
        )

      assert result.szs_status == "GaveUp"
      assert result.exit_status == -1
    end
  end

  describe "run_benchmark/3" do
    test "handles empty problem list" do
      assert LocalRunner.run_benchmark([:tableaux], [], timeout_seconds: 10) == []
    end

    test "handles empty prover list" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "atp_empty_prov_#{System.unique_integer([:positive])}")

      [path | _] = AtpBenchmarkRunner.install_tptp_examples!(root_dir: tmp_dir, force: true)

      assert LocalRunner.run_benchmark([], [Problem.from_tptp_file(path)], timeout_seconds: 10) ==
               []
    end
  end

  describe "local_command/3" do
    test "renders a local command from a prover and problem" do
      prover = Prover.builtin!(:tableaux)
      problem = Problem.new(%{id: "test", name: "test.p", path: "/tmp/test.p"})

      {executable, args, extra} = LocalRunner.local_command(prover, problem, timeout_seconds: 30)

      assert is_binary(executable)
      assert is_list(args)
      assert is_list(extra)
    end
  end

  describe "infer_tableaux_szs" do
    test "detects unsatisfiable from solver status: UNSAT" do
      assert LocalRunner.infer_tableaux_szs("status: UNSAT\nfinal_status: unsat\nclosed", 0) ==
               "Unsatisfiable"
    end

    test "detects satisfiable from solver status: SAT" do
      assert LocalRunner.infer_tableaux_szs("status: SAT\nfinal_status: sat\nmodel: p=true", 0) ==
               "Satisfiable"
    end

    test "detects theorem from explicit text" do
      assert LocalRunner.infer_tableaux_szs("Result: Theorem\nAll branches closed", 0) ==
               "Theorem"
    end

    test "detects theorem via 'valid'" do
      assert LocalRunner.infer_tableaux_szs("The formula is valid.", 0) == "Theorem"
    end

    test "does NOT match bare 'true' as Theorem" do
      output = "status: SAT\ntrue_atoms_count: 1\np => true"
      refute LocalRunner.infer_tableaux_szs(output, 0) == "Theorem"
      assert LocalRunner.infer_tableaux_szs(output, 0) == "Satisfiable"
    end

    test "detects GaveUp on unknown output" do
      assert LocalRunner.infer_tableaux_szs("some random output", -1) == "GaveUp"
    end

    test "detects timeout by exit code" do
      assert LocalRunner.infer_tableaux_szs("was interrupted", 124) == "Timeout"
    end

    test "detects timeout by output text" do
      assert LocalRunner.infer_tableaux_szs("cpu limit reached: Timeout", 1) == "Timeout"
    end

    test "detects SZS status in output first" do
      assert LocalRunner.infer_tableaux_szs("% SZS status Theorem\nstatus: SAT", 0) == "Theorem"
    end

    test "explicit SZS GaveUp wins over internal status: SAT" do
      # The solver deliberately emits GaveUp when a theorem is not refuted; its
      # internal `status: SAT` log line must not override that.
      output = "% SZS status GaveUp\nstatus: SAT\nfinal_status: sat"
      assert LocalRunner.infer_tableaux_szs(output, 0) == "GaveUp"
    end

    test "explicit SZS Satisfiable wins over internal status: SAT" do
      output = "% SZS status Satisfiable\nstatus: SAT\nfinal_status: sat"
      assert LocalRunner.infer_tableaux_szs(output, 0) == "Satisfiable"
    end

    test "explicit SZS Unsatisfiable wins over internal status: SAT" do
      output = "% SZS status Unsatisfiable\nstatus: SAT\nfinal_status: sat"
      assert LocalRunner.infer_tableaux_szs(output, 0) == "Unsatisfiable"
    end
  end
end
