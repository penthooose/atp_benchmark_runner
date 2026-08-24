# ATP Benchmark Runner

Elixir library for StarExec-like ATP benchmark runs from local scripts or Livebook.
The runner focuses on benchmark orchestration and reporting; FAU HPC access is
delegated to the local `hpc_connect` library from item #15.

## Current scope

- Define benchmark runs from TPTP problem names or paths
- Pick problems by bare filename (`"GRP001-0.p"`) or directory hint (`"Problems/REL/REL001+0.p"`)
- Register built-in provers: AISE Tableaux, Vampire, E-Prover, CVC5, Leo-III,
  LEO-II, Zipperposition (also `Zipperpin`), Lash
- Generate one SLURM job array per prover
- Submit/query/cancel jobs via `hpc_connect`
- Sync local TPTP problem selections to HPC storage
- Monitor SLURM/result progress with Livebook-friendly progress bars
- Collect remote result files back into parsed SZS result structs
- Parse SZS statuses and aggregate comparison reports
- Persist run manifests, parsed results, config snapshots, and Livebook recovery data as JSON
- Kino dashboard, TPTP selection, monitor, and report panels for Livebook
- One provider module and Apptainer definition template per prover
- Upload ATP prover definition files and build `.sif` images through `hpc_connect`
- Optional Oban scheduler for nightly runs
- Webhook and email-ready completion summaries

## Quick start

```elixir
# Point at your TPTP install or let it default to ./tmp/tptp
System.put_env("TPTP_ROOT", "./tmp/tptp")

# Or download the official archive (~881MB) straight from Livebook:
AtpBenchmarkRunner.ensure_tptp_archive(root_dir: "./tmp/tptp")

# Pick problems by name — resolved from user dir, bundled, or archive
problems = AtpBenchmarkRunner.select_problems([
  "GRP001-0.p", "LAT001+0.p", "Problems/REL/REL001+0.p"
])

# Run a local benchmark
plan = AtpBenchmarkRunner.bootstrap([:vampire, :eprover], problems,
  mode: :local, timeout_seconds: 120, auto_ensure_images: true
)
results = AtpBenchmarkRunner.run_benchmark(plan)
AtpBenchmarkRunner.results_table(results)
```

See `examples/benchmark_local.livemd` for the full notebook.

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

Three ways to get problem files:

**1. Drop files into the user examples dir** — `<tptp_dir>/user_examples/`. Highest priority,
checked before everything else. Overrides same-named files from the archive or bundled
examples. Just put your `.p` or `.ax` files there.

**2. Bundled smoke examples** — `priv/tptp_examples/`. Auto-copied to `./tmp/tptp_examples/`
on first use. 12 tiny problems across CNF, FOF and THF, good for quick smoke tests.

**3. Full TPTP archive** — download and extract the official distribution from tptp.org
(large, opt-in). Installed under `<tptp_dir>/TPTP-v9.2.1/`.

Important env vars:

| Var                                         | Default                            | What                       |
| ------------------------------------------- | ---------------------------------- | -------------------------- |
| `TPTP_ROOT`                                 | `./tmp/tptp`                       | TPTP library root          |
| `ATP_BENCHMARK_RUNNER_USER_EXAMPLES_DIR`    | `<TPTP_ROOT>/user_examples`        | Your custom problem files  |
| `ATP_BENCHMARK_RUNNER_BUNDLED_EXAMPLES_DIR` | `./tmp/tptp_examples`              | Bundled smoke example copy |
| `ATP_BENCHMARK_RUNNER_STORE_DIR`            | `./tmp/atp_benchmark_runner_store` | Run results and reports    |

Picking problems by name:

```elixir
# Bare filenames — resolved from user dir, bundled tmp, or archive index
AtpBenchmarkRunner.select_problems(["GRP001-0.p", "LAT001+0.p", "USR001+0.ax"])

# With directory hint
AtpBenchmarkRunner.select_problems([
  "Problems/REL/REL001+0.p",
  "Axioms/SET/SET001+0.ax"
])
```

If a file is not found anywhere, it's skipped with a warning that lists
the checked directories.

```elixir
# Tiny bundled smoke examples
AtpBenchmarkRunner.install_tptp_examples!()

# Full official distribution (opt-in, ~881MB)
AtpBenchmarkRunner.ensure_tptp_archive(version: "9.2.1")

# Filter by form, rating, domain — only with full archive
problems =
   AtpBenchmarkRunner.load_tptp_problems(
      forms: ["THF", "FOF"],
      rating_max: 0.25,
      limit: 100
   )
```

## Local / Livebook usage

```elixir
# 1. Pick problems by name — resolved from user dir, bundled tmp, or archive
problems = AtpBenchmarkRunner.select_problems([
  "GRP001-0.p", "LAT001+0.p", "Problems/REL/REL001+0.p"
])

# 2. Bootstrap a plan
plan = AtpBenchmarkRunner.bootstrap(provers, problems,
  mode: :local,
  timeout_seconds: 120,
  auto_ensure_images: true
)

# 3. Run the benchmark
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

### Visualizing results (Mermaid)

`visualize/1` is the visual companion to `explain/1` and `explain_full/1`.
Inside Livebook it returns `Kino.Mermaid` diagrams; elsewhere it returns a
fenced markdown block you can paste into a markdown cell.

```elixir
# Single result → prover → problem → status → timing flowchart
AtpBenchmarkRunner.visualize(result)

# List → status pie + wall-time chart (pushed as two Livebook outputs)
AtpBenchmarkRunner.visualize(results)

# Report → aggregated scoreboard
AtpBenchmarkRunner.visualize(report)

# Proof → dependency DAG for E/Vampire-style TPTP clause refutations
AtpBenchmarkRunner.visualize_proof(result)
```

Raw builders live in `AtpBenchmarkRunner.Visualize` (`result/2`, `proof/2`,
`status_pie/2`, `timeline/2`, `report/2`); use `Visualize.markdown/1` to wrap a
diagram in a `mermaid` code fence for copy-paste. Mermaid is used instead of
eflambe flame graphs because the reference provers run as external OS
processes (no BEAM to profile); the wall-time chart is the closest data-driven
flame-graph analogue. See `AtpBenchmarkRunner.Visualize` for details.

## HPC / SLURM usage

Requires a configured `hpc_connect` session.

### Node size

The `:node_size` option controls how many CPUs of a cluster node are requested:

| Value   | `--exclusive` | CPUs per task                 | Use case                              |
| ------- | ------------- | ----------------------------- | ------------------------------------- |
| `:full` | Yes           | All node CPUs (auto-detected) | Maximise per-prover throughput        |
| `:half` | No            | Half the node's CPUs          | Share node with other jobs; efficient |

CPU counts are auto-detected per cluster and partition:

| Cluster | Partition  | `:full` CPUs | `:half` CPUs |
| ------- | ---------- | ------------ | ------------ |
| Helma   | `cpu`      | 384          | 192          |
| Fritz   | singlenode | 72           | 36           |
| Fritz   | spr1tb     | 104          | 52           |
| Fritz   | spr2tb     | 104          | 52           |

Override any derived value explicitly via `:cpus_per_task` or `:exclusive` in bootstrap opts.

### Execution modes

Three HPC execution modes are available via the `bootstrap/4` call:

| Mode                                 | `hpc_mode`     | `single_node_mode` | Resource allocation                                                                                         |
| ------------------------------------ | -------------- | ------------------ | ----------------------------------------------------------------------------------------------------------- |
| **Single-node sequential** (default) | `:single_node` | `:sequential`      | All provers on 1 node. Tasks run one-at-a-time; each gets the node's CPUs (`:full` or `:half`).             |
| **Single-node parallel**             | `:single_node` | `:parallel`        | All provers on 1 node. Tasks run concurrently (≤ `max_parallel_jobs`); each gets a share (`:full`/`:half`). |
| **Multi-node**                       | `:multi_node`  | —                  | Each prover on its own node. Separate SLURM job per prover.                                                 |

```elixir
boot = HpcConnect.bootstrap(mode: :local, env_file: ".env")
session = boot.session

# ── Single-node sequential, full node (default) ──────────────
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,
  single_node_mode: :sequential,
  timeout_seconds: 300
)
results = AtpBenchmarkRunner.run_benchmark(plan)

# ── Single-node sequential, half node ────────────────────────
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,
  single_node_mode: :sequential,
  node_size: :half,
  timeout_seconds: 300
)
results = AtpBenchmarkRunner.run_benchmark(plan)

# ── Single-node parallel ─────────────────────────────────────
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,
  single_node_mode: :parallel,
  max_parallel_jobs: 4,
  timeout_seconds: 300
)
results = AtpBenchmarkRunner.run_benchmark(plan)

# ── Multi-node: each prover on its own node ──────────────────
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :multi_node,
  timeout_seconds: 300
)
results = AtpBenchmarkRunner.run_benchmark(plan)
```

### Low-level job submission (bypassing bootstrap/run_benchmark)

```elixir
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

### Node size (`:node_size`)

Controls how many CPUs are requested per cluster node. Auto-detected per cluster
and partition; can be overridden explicitly.

| Value   | `--exclusive` | Helma CPU | Fritz singlenode | Fritz spr\* |
| ------- | ------------- | --------- | ---------------- | ----------- |
| `:full` | Yes           | 384 CPUs  | 72 CPUs          | 104 CPUs    |
| `:half` | No            | 192 CPUs  | 36 CPUs          | 52 CPUs     |

### Single-node sequential (default)

All provers on one node. Tasks run one at a time — each gets the node's CPUs
(controlled by `node_size`). Best for comparing a small number of provers.

```elixir
# Full node (default)
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,
  single_node_mode: :sequential,
  timeout_seconds: 120
)

# Half node — share cluster node with other jobs
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,
  single_node_mode: :sequential,
  node_size: :half,
  timeout_seconds: 120
)
```

### Single-node parallel

All provers on one node. Tasks run concurrently up to `max_parallel_jobs`.
Each gets a share of CPUs. Best for large problem sets.

```elixir
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :single_node,
  single_node_mode: :parallel,
  node_size: :full,
  max_parallel_jobs: 4,
  timeout_seconds: 120
)
```

### Multi-node (prover per node)

Each prover runs on its own node via separate SLURM jobs.
`node_size` controls whether each prover gets a full or half node.

```elixir
plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
  mode: :hpc,
  hpc_mode: :multi_node,
  timeout_seconds: 120
)
```
