defmodule AtpBenchmarkRunner.ConvenienceTest do
  # Env-var and store mutations are global, so run serially.
  use ExUnit.Case, async: false

  alias AtpBenchmarkRunner.{Config, LocalRunner, Problem, Result, Run}

  describe "Config.sif_dir/1" do
    test "honours the ATP_BENCHMARK_RUNNER_SIF_DIR env var" do
      System.put_env("ATP_BENCHMARK_RUNNER_SIF_DIR", "C:/sif")
      assert Config.sif_dir() == Path.expand("C:/sif")
    after
      System.delete_env("ATP_BENCHMARK_RUNNER_SIF_DIR")
    end
  end

  describe "LocalRunner.local_sif_path/1" do
    test "uses sif_name when set, otherwise the prover name" do
      assert LocalRunner.local_sif_path(:vampire) |> Path.basename() == "vampire.sif"

      assert LocalRunner.local_sif_path(:tableaux) |> Path.basename() ==
               "simple_tableaux_solver.sif"
    end
  end

  describe "LocalRunner.detect_apptainer_available/0" do
    test "returns a boolean" do
      assert is_boolean(LocalRunner.detect_apptainer_available())
      assert is_map(LocalRunner.detect_available().apptainer_images)
    end
  end

  describe "LocalRunner.build_images!/2" do
    test "empty prover list returns an empty result list" do
      assert LocalRunner.build_images!([]) == []
    end

    test "unknown provers become error entries without raising" do
      assert [{:error, :nonexistent_prover_xyz, _}] =
               LocalRunner.build_images!([:nonexistent_prover_xyz])
    end

    test "results are shape-matched tuples for every registered prover" do
      # Uses the Apptainer backend so the test never triggers slow Docker builds;
      # without a local Apptainer install every entry is an error, still fast.
      results = LocalRunner.build_images!(:all, backend: :apptainer)

      assert length(results) == length(AtpBenchmarkRunner.built_in_provers())
      assert Enum.all?(results, &(match?({:ok, _}, &1) or match?({:error, _, _}, &1)))
    end
  end

  describe "AtpBenchmarkRunner.persist_run!/4" do
    test "saves run, results, and report and returns their paths" do
      dir = Path.join(System.tmp_dir!(), "atp_conv_#{System.unique_integer([:positive])}")

      problem = Problem.new(id: "p1", name: "GRP001-0", path: "/tmp/GRP001-0.p")
      run = Run.new(id: "conv_run", problems: [problem], provers: [:vampire])
      results = [Result.new(problem_id: "p1", prover: :vampire, szs_status: "Theorem")]
      report = AtpBenchmarkRunner.report(results)

      paths = AtpBenchmarkRunner.persist_run!(run, results, report, dir: dir)

      assert paths.run_path =~ "conv_run.run.json"
      assert paths.results_path =~ "conv_run.results.json"
      assert paths.report_path =~ "conv_run.report.json"
      assert File.exists?(paths.run_path)
      assert File.exists?(paths.results_path)
      assert File.exists?(paths.report_path)
    end
  end

  describe "AtpBenchmarkRunner.load_env!/1" do
    test "applies KEY=VALUE pairs to the OS environment" do
      path = Path.join(System.tmp_dir!(), "atp_env_#{System.unique_integer([:positive])}.env")

      on_exit(fn ->
        System.delete_env("ATP_TEST_KEY")
        File.rm(path)
      end)

      File.write!(path, "ATP_TEST_KEY=hello\n")

      env = AtpBenchmarkRunner.load_env!(path)

      assert env["ATP_TEST_KEY"] == "hello"
      assert System.get_env("ATP_TEST_KEY") == "hello"
    end
  end
end
