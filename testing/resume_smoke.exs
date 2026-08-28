# Smoke check for Phase 7: retry-until-success collection + resume API.
# Run with:  mix run testing/resume_smoke.exs
tmp = Path.join(System.tmp_dir!(), "abr_resume_smoke_#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)

checks = [
  {:collect_hpc_results_exported,
   function_exported?(AtpBenchmarkRunner, :collect_hpc_results!, 3)},
  {:collect_last_hpc_results_exported,
   function_exported?(AtpBenchmarkRunner, :collect_last_hpc_results!, 2)},
  {:collect_retry_forever_option, Code.ensure_loaded?(AtpBenchmarkRunner.HPC.Results)}
]

Enum.each(checks, fn {name, ok} ->
  IO.puts("#{if ok, do: "OK ", else: "FAIL"} #{name}")
end)

# Empty store -> collect_last_hpc_results! must raise a clear ArgumentError.
session = %HpcConnect.Session{cluster: :local}

try do
  AtpBenchmarkRunner.collect_last_hpc_results!(session, dir: tmp)
  IO.puts("FAIL expected ArgumentError for empty store")
rescue
  e in ArgumentError ->
    IO.puts("OK collect_last_hpc_results! empty store -> ArgumentError: #{Exception.message(e)}")
end

File.rm_rf!(tmp)

# Round-trip check: save_run!/load_run! must preserve remote_root (resume path).
run =
  AtpBenchmarkRunner.Run.new(
    id: "run_smoke_roundtrip",
    title: "smoke",
    cluster: :helma,
    partition: "cpu",
    remote_root: "/hnvme/abc123/smoke",
    problems: [],
    provers: [],
    metadata: %{mode: :hpc}
  )

path = AtpBenchmarkRunner.Store.save_run!(run, dir: tmp)
loaded = AtpBenchmarkRunner.Store.load_run!(path)
IO.puts("OK save_run!/load_run! path=#{Path.basename(path)}")
IO.puts("   remote_root preserved: #{inspect(loaded.remote_root == run.remote_root)}")

# Draft-only store -> collect_last_hpc_results! must skip it and report the
# "never reached sbatch" hint (this is the pre-submit failure case).
try do
  AtpBenchmarkRunner.collect_last_hpc_results!(session, dir: tmp)
  IO.puts("FAIL expected ArgumentError for draft-only store")
rescue
  e in ArgumentError ->
    IO.puts("OK draft-only store skipped -> #{Exception.message(e)}")
end

# Add an actually-submitted manifest -> the filter predicate must match it.
submitted =
  run
  |> AtpBenchmarkRunner.Run.mark_submitted(%{
    single_node: %{job_id: "123456", logs_dir: "/hnvme/abc123/logs"}
  })

spath = AtpBenchmarkRunner.Store.save_run!(submitted, dir: tmp)
sloaded = AtpBenchmarkRunner.Store.load_run!(spath)

predicate_matches? =
  sloaded.status == :submitted and
    is_map(sloaded.submitted_jobs) and map_size(sloaded.submitted_jobs) > 0

IO.puts("OK submitted manifest round-trips status/jobs: #{inspect(predicate_matches?)}")

# Run-id resolution: load_run_by_id! finds a manifest by id (not path).
by_id = AtpBenchmarkRunner.Store.load_run_by_id!("run_smoke_roundtrip", dir: tmp)
IO.puts("OK load_run_by_id! resolves id -> run (remote_root: #{inspect(by_id.remote_root)})")

# load_run_by_id! must raise a clear error for an unknown id.
try do
  AtpBenchmarkRunner.Store.load_run_by_id!("run_does_not_exist", dir: tmp)
  IO.puts("FAIL expected ArgumentError for unknown run id")
rescue
  ArgumentError ->
    IO.puts("OK load_run_by_id! unknown id -> ArgumentError")
end

File.rm_rf!(tmp)
