defmodule AtpBenchmarkRunner.HPC.JobScriptTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.{Problem, Prover, Run}
  alias AtpBenchmarkRunner.HPC.JobScript

  defp run(metadata) do
    Run.new(%{id: "run_test", problems: [], provers: [], metadata: metadata})
  end

  test "uses the prepared input path recorded by the runner" do
    problem = Problem.new(%{id: "THF001+0", name: "THF001+0", path: "/vault/tptp/THF001+0.p"})
    prover = Prover.builtin!(:shot_tx)

    prepared =
      run(%{prepared_inputs: %{"shot_tx|THF001+0" => "/vault/tptp/THF001+0_abc_expanded.p"}})

    assert JobScript.prepared_input_path(prepared, prover, problem) ==
             "/vault/tptp/THF001+0_abc_expanded.p"
  end

  test "falls back to the derived path for a manifest without prepared inputs" do
    problem = Problem.new(%{id: "GRP001-0", name: "GRP001-0", path: "/vault/tptp/GRP001-0.p"})
    prover = Prover.builtin!(:shot_tx)

    assert JobScript.prepared_input_path(run(%{}), prover, problem) ==
             "/vault/tptp/GRP001-0_thf.p"
  end

  test "reads string-keyed metadata from a reloaded manifest" do
    problem = Problem.new(%{id: "THF001+0", name: "THF001+0", path: "/vault/tptp/THF001+0.p"})
    prover = Prover.builtin!(:shot_tx)

    prepared = run(%{"prepared_inputs" => %{"shot_tx|THF001+0" => "/vault/tptp/x.p"}})

    assert JobScript.prepared_input_path(prepared, prover, problem) == "/vault/tptp/x.p"
  end
end
