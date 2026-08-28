# Smoke: remote-cluster run discovery for the resume API (Phase 7).
# Run with:  mix run testing/remote_resume_smoke.exs
env_file = Path.expand("./.env", File.cwd!())
AtpBenchmarkRunner.load_env!(env_file)

boot = HpcConnect.bootstrap(mode: :local, env_file: env_file)
session = boot.session

IO.puts("Session cluster=#{session.cluster.name}")
IO.puts("  work_dir=#{session.work_dir}")
IO.puts("  vault_dir=#{inspect(session.vault_dir)}")
IO.puts("")

# Known old remote run (verified via `ssh helma` earlier) -> remote fallback.
run = AtpBenchmarkRunner.HPC.Results.find_remote_run(session, "run_20260705_144735_1608")
IO.puts("find_remote_run run_20260705_144735_1608 -> #{inspect(run && run.id)}")
IO.puts("  remote_root=#{inspect(run && run.remote_root)}")

# Newest remote run dir -> should resolve to the newest run_results/ run.
latest = AtpBenchmarkRunner.HPC.Results.latest_remote_run(session)
IO.puts("latest_remote_run -> #{inspect(latest && latest.id)}")
IO.puts("  remote_root=#{inspect(latest && latest.remote_root)}")

# Unknown run (never submitted) -> nil.
nil_run = AtpBenchmarkRunner.HPC.Results.find_remote_run(session, "run_20260827_155553_1028")
IO.puts("find_remote_run unknown run_20260827_155553_1028 -> #{inspect(nil_run)}")

# collect_last_hpc_results! with no local submitted run -> falls back to the
# newest remote run (finite retries, so it returns [] fast for an empty run).
IO.puts("")
IO.puts("latest struct: #{inspect(latest && latest.__struct__)}")
IO.puts("latest is Run? #{match?(%AtpBenchmarkRunner.Run{}, latest)}")

try do
  r = AtpBenchmarkRunner.collect_hpc_results!(session, latest, collect_retry_forever: false)
  IO.puts("direct collect_hpc_results!(latest) -> #{length(r)} results")
rescue
  e -> IO.puts("direct collect_hpc_results!(latest) raised: #{Exception.message(e)}")
end

# The user's exact flow: resume a specific run by id via the remote fallback.
try do
  r = AtpBenchmarkRunner.collect_hpc_results!(session, "run_20260821_231452_194")
  IO.puts("by-id collect_hpc_results!(run_20260821_231452_194) -> #{length(r)} results")
rescue
  e -> IO.puts("by-id collect_hpc_results! raised: #{Exception.message(e)}")
end

try do
  case AtpBenchmarkRunner.collect_last_hpc_results!(session) do
    results ->
      IO.puts("collect_last_hpc_results! returned #{length(results)} results (finite collect)")
  end
rescue
  e -> IO.puts("collect_last_hpc_results! raised: #{Exception.message(e)}")
end
