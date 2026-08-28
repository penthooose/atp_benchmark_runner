defmodule AtpBenchmarkRunner.HPC.ResultsTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.HPC.Results

  describe "classify_job_output/1" do
    test "empty output (job gone from sacct) is terminal" do
      assert Results.classify_job_output("") == :terminal
      assert Results.classify_job_output("   \n") == :terminal
    end

    test "all-completed states are terminal" do
      output = "123456 COMPLETED\n123457 COMPLETED\n"
      assert Results.classify_job_output(output) == :terminal
    end

    test "any running/pending state keeps the job active" do
      output = "123456 RUNNING\n123457 PENDING\n"
      assert Results.classify_job_output(output) == :running
    end

    test "a mix of terminal and running states is active" do
      output = "123456 COMPLETED\n123457 RUNNING\n"
      assert Results.classify_job_output(output) == :running
    end

    test "failure states are terminal" do
      output = "123456 FAILED\n123457 TIMEOUT\n"
      assert Results.classify_job_output(output) == :terminal
    end

    test "trailing whitespace is tolerated" do
      assert Results.classify_job_output("123456 RUNNING \n") == :running
      assert Results.classify_job_output("123456 COMPLETED \n") == :terminal
    end
  end
end
