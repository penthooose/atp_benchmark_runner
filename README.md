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

## Prover integration strategy

The public ecosystem does not currently provide mature Elixir-native bindings for
Vampire, E, CVC5, Zipperposition, LEO-II, or Leo-III. The robust implementation
strategy is therefore:

1. **Elixir orchestrates** benchmark configuration, SLURM submission, monitoring,
   result parsing, and reporting.
2. **Each prover remains a CLI tool** behind a provider module in
   `lib/atp_benchmark_runner/provers/`.
3. **HPC uses Apptainer `.sif` images** built from bundled definitions in
   `priv/provers/<name>/apptainer.def`.
4. **Kubernetes remains optional**: `AtpBenchmarkRunner.kubernetes_job/3` can
   produce a manifest map from the same provider metadata for future cloud runs.

Research summary:

```elixir
AtpBenchmarkRunner.prover_research_summary()
```

Image preparation plan:

```elixir
run = AtpBenchmarkRunner.new_run(problems: ["/remote/TPTP/demo.p"], provers: [:vampire, :eprover])
AtpBenchmarkRunner.image_plan(run.provers)
```

Session-aware image build plan:

```elixir
AtpBenchmarkRunner.image_build_plan(session, run.provers)
```

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

## Local / IEx usage

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

# Submit for real. Pass prepare_images: true once the bundled Apptainer
# definitions have been reviewed/pinned for your target cluster.
submitted = AtpBenchmarkRunner.submit(session, run, dry_run: false, prepare_images: true)
AtpBenchmarkRunner.monitor(session, submitted)

results = AtpBenchmarkRunner.collect_results(session, submitted)
AtpBenchmarkRunner.save_results!(submitted, results)
report = AtpBenchmarkRunner.report(results, submitted)
AtpBenchmarkRunner.write_email_summary!(report, submitted)
```

Webhook completion notifications use `ATP_BENCHMARK_RUNNER_WEBHOOK_URL` or an
explicit `webhook_url:` option:

```elixir
AtpBenchmarkRunner.send_webhook_notification(report, submitted)
```

## Livebook usage

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

See `examples/benchmark_smoke.livemd` for an end-to-end notebook skeleton:
TPTP selection, image planning/building, job submission, monitoring, collection,
and report rendering.

## Notes

- The `hpc_connect` dependency currently uses a local path while item #15 is in
  active development. `mix.exs` contains the GitHub dependency shape to use once
  that repository is published.
- Prover Apptainer images are expected under
  `<session.work_dir>/singularity_images/<prover>.sif` unless a prover-specific
  `sif_path` is configured.
- The bundled definitions are starting templates. Before a production nightly run,
  build each image once on the target HPC environment and pin any release URLs that
  upstream projects publish in non-uniform asset names.
- Remote image builds and smoke validation still need to be exercised on the real
  target cluster before treating the templates as production-pinned artifacts.
