# ATP Benchmark Runner

Elixir library for StarExec-like ATP benchmark runs from local scripts or Livebook.
The runner focuses on benchmark orchestration and reporting; FAU HPC access is
delegated to the local `hpc_connect` library from item #15.

## Current scope

- Define benchmark runs over TPTP problem paths or names
- Register built-in provers: AISE Tableaux, Vampire, E-Prover, CVC5, Leo-III,
  LEO-II, Zipperposition (also accepting the ticket alias `Zipperpin`), Lash
- Generate one SLURM job array per prover
- Submit/query/cancel jobs via `hpc_connect`
- Sync local TPTP problem selections to HPC storage
- Monitor SLURM/result progress with Livebook-friendly progress bars
- Collect remote result files back into parsed SZS result structs
- Parse SZS statuses and aggregate comparison reports
- Persist run manifests, parsed results, config snapshots, and Livebook recovery data as JSON
- Provide Kino dashboard, TPTP selection, monitor, and report panels for Livebook
- Bundle one provider module and one Apptainer definition template per prover
- Upload ATP prover definition files and build `.sif` images through `hpc_connect`
- Provide an optional Oban scheduler boundary for host applications that want nightly runs
- Emit webhook payloads and email-ready Markdown completion summaries

## Apptainer image build workflow

ATP-specific image definitions live in this project under
`priv/provers/<name>/apptainer.def`. They are intentionally **not** copied into
the `hpc_connect` dependency's `priv/` directory: dependencies may be fetched,
rebuilt, or replaced, and `hpc_connect` should remain generic infrastructure.

Instead, the runner uses the public `hpc_connect` API:

1. Upload generic build scripts from `hpc_connect`:
   `AtpBenchmarkRunner.HPC.Images.install_build_tools!/2`
2. Upload ATP-specific `.def` files to
   `<session.work_dir>/singularity_def_files/<name>.def`:
   `AtpBenchmarkRunner.upload_prover_definitions!/3`
3. Build images through the generic `hpc_connect` `build_sif.sh` workflow:
   `AtpBenchmarkRunner.build_prover_images!/3`

```elixir
run = AtpBenchmarkRunner.new_run(provers: [:vampire, :eprover, :cvc5])

# Dry-run inspect local/remote paths first.
AtpBenchmarkRunner.image_build_plan(session, run.provers)

# Upload definitions only.
AtpBenchmarkRunner.upload_prover_definitions!(session, run.provers)

# Build all selected images. By default, hpc_connect uses its build-capable
# fallback cluster strategy unless build_cluster: is explicitly set.
AtpBenchmarkRunner.build_prover_images!(session, run.provers, force_rebuild: false)
```

Remote convention:

- definitions: `<session.work_dir>/singularity_def_files/<name>.def`
- images: `<session.work_dir>/singularity_images/<name>.sif`
- build script: `<session.work_dir>/scripts/build_sif.sh`

After building, run a small smoke validation before production benchmarks:

```elixir
AtpBenchmarkRunner.smoke_validate_images!(session, run.provers)
```

## TPTP problem management

Local problem storage is configured through `.env` with
`ATP_BENCHMARK_RUNNER_TPTP_DIR`. The example `.env` points at the workspace-level
`tmp/tptp_problems` directory used for copied examples from item #12. Livebook
can instead use its cache directory via `AtpBenchmarkRunner.tptp_panel/1`.

```elixir
# Tiny bundled smoke examples, safe for tests and first notebooks.
AtpBenchmarkRunner.install_tptp_examples!()

# Full official distribution, opt-in because it is large.
AtpBenchmarkRunner.ensure_tptp_archive(version: "9.2.1")

problems =
   AtpBenchmarkRunner.load_tptp_problems(
      forms: ["THF", "FOF"],
      rating_max: 0.25,
      limit: 100
   )

remote_problems = AtpBenchmarkRunner.sync_tptp_problems!(session, problems)
```

## Local / Livebook usage

```elixir
# 1. Bootstrap a plan — does not execute anything
plan = AtpBenchmarkRunner.bootstrap(provers, problems,
  mode: :local,
  timeout_seconds: 120,
  auto_ensure_images: true
)

# 2. Run the benchmark — prints timing info
results = AtpBenchmarkRunner.run_benchmark(plan)

# 3. Results table (markdown table printed to stdout)
AtpBenchmarkRunner.results_table(results)

# 4. Compact per-result summary
AtpBenchmarkRunner.verbose_report(results) |> Enum.each(&IO.puts/1)

# 5. Full details with proofs
AtpBenchmarkRunner.explain_full(results) |> IO.puts()

# 6. Show proof for a specific prover/problem
AtpBenchmarkRunner.show_proof(results, :vampire, "GRP001-0")

# 7. Aggregated report map (Livebook tables, Markdown, JSON)
report = AtpBenchmarkRunner.report(results)

# 8. Print report tables to stdout
AtpBenchmarkRunner.print_per_prover(report)
AtpBenchmarkRunner.print_per_problem(report)
AtpBenchmarkRunner.print_interesting(report)
AtpBenchmarkRunner.print_report(report)  # all of the above

# 9. Persist results
run = AtpBenchmarkRunner.new_run(title: "Smoke test", problems: problems, provers: provers)
AtpBenchmarkRunner.save_run!(run)
AtpBenchmarkRunner.save_results!(run, results)
AtpBenchmarkRunner.save_report!(run, report)

# 10. Compare with a previous run (longitudinal diff)
diff = AtpBenchmarkRunner.compare_runs(prev_results, results)
IO.puts(AtpBenchmarkRunner.diff_markdown(diff))
```

## HPC / SLURM usage

Requires a configured `hpc_connect` session.

```elixir
boot = HpcConnect.bootstrap(mode: :local, env_file: ".env")
session = boot.session

run =
  AtpBenchmarkRunner.new_run(
    title: "THF smoke test",
    partition: "singlenode",
    walltime: "02:00:00",
    problem_timeout_seconds: 300,
    max_parallel_jobs: 32,
    problems: ["$HOME/tptp/Problems/SET/SET001^1.p"],
    provers: [:tableaux, :vampire, :eprover, :cvc5]
  )

# Inspect generated scripts without touching the cluster.
plan = AtpBenchmarkRunner.submit(session, run, dry_run: true)

# Submit for real.
submitted = AtpBenchmarkRunner.submit(session, run, dry_run: false, prepare_images: true)
AtpBenchmarkRunner.monitor(session, submitted)

results = AtpBenchmarkRunner.collect_results(session, submitted)
AtpBenchmarkRunner.save_results!(submitted, results)
report = AtpBenchmarkRunner.report(results, submitted)
AtpBenchmarkRunner.write_email_summary!(report, submitted)
```

Webhook completion notifications use `ATP_BENCHMARK_RUNNER_WEBHOOK_URL`:

```elixir
AtpBenchmarkRunner.send_webhook_notification(report, submitted)
```

## Livebook dashboard

```elixir
boot =
  HpcConnect.prepare_livebook_session(cluster: :fritz, persist_form: true)
  |> HpcConnect.bootstrap()

AtpBenchmarkRunner.livebook_dashboard(boot.session)
AtpBenchmarkRunner.tptp_panel()
AtpBenchmarkRunner.monitor_panel(boot.session, submitted_run)
AtpBenchmarkRunner.report_panel(results, submitted_run)
```

The dashboard stores recovery manifests under the cache directory returned by
`AtpBenchmarkRunner.GUI.Cache.cache_dir/1`. This is deliberate: if a Livebook cell
is interrupted or recompiled, the submitted job IDs can be recovered from JSON.

See `examples/benchmark_local.livemd` for an end-to-end notebook skeleton:
TPTP selection, image planning/building, job submission, monitoring, collection,
and report rendering.

## HPC bootstrap modes

```elixir
# Single-node: all provers on one compute node (job array)
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,  # default
  timeout_seconds: 120
)

# Multi-node: one prover per compute node
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :multi_node
)
```
