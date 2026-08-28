# Full HPC benchmark via `mix run`, the reliable path.
#
# The Livebook embedded runtime on Windows can die during the SSH-heavy
# sync/submit phase ("Runtime terminated unexpectedly - no connection"), even
# though the exact same code works under `mix run`. This script runs the
# whole §1→§7 notebook flow outside Livebook:
#
#     bootstrap -> build plan -> run_benchmark (sync + submit + wait + collect)
#
# Results are persisted to the store, so you can analyse them in Livebook
# afterwards (report / visualizations / MultiRun) and resume via
# `collect_last_hpc_results!(session)`.
#
# Run with:   mix run testing/run_hpc_benchmark.exs
env_file = Path.expand("./.env", File.cwd!())
AtpBenchmarkRunner.load_env!(env_file)

boot = HpcConnect.bootstrap(mode: :local, env_file: env_file)
session = boot.session

IO.puts(
  "cluster=#{session.cluster.name} steady=#{session.steady_connection} retry_forever=#{session.retry_forever}"
)

IO.puts("")

selected_provers = [
  :tableaux,
  :shot_tx,
  :eprover,
  :vampire,
  :cvc5,
  :zipperposition,
  :leo3,
  :leo2,
  :lash
]

names = [
  "ALG001+0",
  "GRP001-0",
  "GRP002+0",
  "GRP003+0",
  "GRP004+0",
  "GRP720+1",
  "GRP752-1",
  "LAT001+0",
  "PUZ001+0",
  "REL001+0",
  "SET001^0",
  "SMT001+0",
  "SYN000+0",
  "THF001+0"
]

# In a `mix run` context the bundled examples are not resolved through the
# TPTP name index, so build the Problem structs directly from bundled_examples().
bundled = AtpBenchmarkRunner.TPTP.bundled_examples()

problems =
  Enum.filter(bundled, fn p ->
    String.replace_suffix(p.name || "", ".p", "") in names
  end)

if problems == [] do
  IO.puts("ERROR: no bundled problems resolved")
  System.halt(1)
end

plan =
  AtpBenchmarkRunner.bootstrap(session, selected_provers, problems,
    mode: :hpc,
    hpc_mode: :single_node,
    single_node_mode: :sequential,
    timeout_seconds: 30,
    wait_for_completion: true,
    prepare_images: false
  )

IO.puts("Run ID: #{plan.id}")
IO.puts("Provers: #{inspect(selected_provers)}")
IO.puts("Problems: #{length(problems)}")
IO.puts("Plan mode: single_node/sequential   Partition: #{plan.metadata[:hpc][:partition]}")
IO.puts("")

{t_ms, results} =
  :timer.tc(fn ->
    try do
      AtpBenchmarkRunner.run_benchmark(plan)
    rescue
      e ->
        IO.puts("Benchmark failed: #{Exception.message(e)}")
        []
    end
  end)

IO.puts("")
IO.puts("Benchmark finished in #{Float.round(t_ms / 1_000_000, 2)}s")
IO.puts("Results: #{length(results)}")

if results != [] do
  report = AtpBenchmarkRunner.report(results, plan)
  AtpBenchmarkRunner.print_report_markdown(report)

  run =
    AtpBenchmarkRunner.new_run(
      title: "HPC benchmark (mix run)",
      problems: problems,
      provers: selected_provers,
      walltime: "02:00:00",
      problem_timeout_seconds: 30
    )

  paths = AtpBenchmarkRunner.persist_run!(run, results, report)
  IO.puts("")
  IO.puts("Run saved: #{paths.run_path}")
  IO.puts("Results saved: #{paths.results_path}")
  IO.puts("Report saved: #{paths.report_path}")
  IO.puts("")

  IO.puts(
    "In Livebook, resume/analyse with:  AtpBenchmarkRunner.collect_last_hpc_results!(session)"
  )
end
