# AtpBenchmarkRunner Manual

`AtpBenchmarkRunner` is a small Elixir library for running automated theorem
proving (ATP) benchmarks: it downloads/selects TPTP problems, runs a set of
provers locally or on an HPC cluster (FAU Helma/Fritz), parses SZS output,
and produces reports, tables, visualizations and persistable artifacts.

Cluster interaction is delegated to the separate local dependency
[`hpc_connect`](../../../item_15_Elixir_HPC_Connect_Library/hpc_connect), so
this package stays focused on benchmark domain logic and reporting. This manual
covers the atp_benchmark_runner workflows; the one-line versions of everything
below are in [`commands_cheat_sheet.md`](./commands_cheat_sheet.md).

---

## 1. Quick start (Livebook)

The library is designed to be `Mix.install`ed into Livebook, local scripts, or
IEx.

```elixir
Mix.install([
  {:atp_benchmark_runner, path: "../atp_benchmark_runner"},
  {:hpc_connect, path: "../../item_15_Elixir_HPC_Connect_Library/hpc_connect"}
])
```

Point all storage into the workspace so runs stay self-contained, then load a
`.env` file for HPC and runner variables:

```elixir
AtpBenchmarkRunner.setup_local(tmp_root: Path.expand("./tmp", __DIR__))
AtpBenchmarkRunner.load_env!("../.env")
```

`setup_local/1` sets `ATP_BENCHMARK_RUNNER_STORE_DIR`, `TPTP_ROOT`,
`ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` and `ATP_BENCHMARK_RUNNER_SMT_THF_DIR` under
`tmp_root`. Without it everything falls back to `~/.cache/atp_benchmark_runner`.

---

## 2. Prover registry (config-driven)

Provers are **not** hardcoded modules. Each prover lives in
`priv/provers/<name>/` and is discovered by scanning for a `prover.exs` spec:

```
priv/provers/
├── _template/            # scaffold, NOT discovered (no prover.exs)
├── vampire/
│   ├── prover.exs        # declarative spec (name, command, input, parser, ...)
│   ├── Containerfile     # local Docker build
│   └── apptainer.def     # HPC SIF build
├── eprover/
├── cvc5/
├── zipperposition/
├── leo3/
├── leo2/
├── lash/
└── tableaux/
```

Query the registry:

```elixir
AtpBenchmarkRunner.Provers.all()             # all prover structs
AtpBenchmarkRunner.Provers.names()           # prover names
AtpBenchmarkRunner.Provers.fetch!(:vampire)  # single prover
AtpBenchmarkRunner.Provers.validate()        # [] when the registry is consistent
```

`Provers.fetch!/1` accepts an atom or a name string, and also resolves aliases.
A new prover is added by creating a directory + `prover.exs` (plus container
files) and, when running under Mix, recompiling so the new `priv` directory is
copied. See [`adding_custom_provers_guide.md`](./adding_custom_provers_guide.md)
for the full handbook.

---

## 3. Local workflow

### 3.1 Image status

`image_status_summary/0` returns a string describing which build tools are
available and which images already exist locally; `print_image_status_summary/0`
prints it directly:

```elixir
AtpBenchmarkRunner.LocalRunner.print_image_status_summary()
```

`LocalRunner.detect_available/0` returns the same facts as a map
(`:docker`, `:apptainer`, `:apptainer_images`, ...) if you need them in code.

### 3.2 Build local images

```elixir
AtpBenchmarkRunner.build_local_images!(:all)
AtpBenchmarkRunner.build_local_images!([:vampire, :eprover], force: true, backend: :apptainer)
```

Optional parameters:

| Option     | Values                           | Default | Meaning                                                                         |
| ---------- | -------------------------------- | ------- | ------------------------------------------------------------------------------- |
| `:backend` | `:auto`, `:docker`, `:apptainer` | `:auto` | Which local build tool to use (`:auto` prefers Docker, falls back to Apptainer) |
| `:force`   | `true`/`false`                   | `false` | Rebuild/pull every image even if present                                        |

`provers` may be `:all` or a list of names/atoms. Returns
`[{:ok, name} | {:error, name, reason}, ...]` so failures never raise.

- **Docker backend** builds each prover's `Containerfile` into a Docker image.
- **Apptainer backend** builds each prover's `apptainer.def` into a local
  `.sif` under `Config.sif_dir/0` (env `ATP_BENCHMARK_RUNNER_SIF_DIR`,
  default `./tmp/singularity_images`). Requires `apptainer` on the PATH.

### 3.3 Problems

```elixir
{problems, warnings} = AtpBenchmarkRunner.download_tptp_problems!(["GRP001-0.p"])
problems = AtpBenchmarkRunner.select_problems(rating_max: 0.1, limit: 15)
problems = AtpBenchmarkRunner.load_tptp_problems()
```

`download_tptp_problems!/1` is best-effort — missing names become warnings,
never an exception. `select_problems/1` takes either explicit names or filter
options (see `AtpBenchmarkRunner.TPTP.select/1`).

### 3.4 Run

```elixir
plan = AtpBenchmarkRunner.bootstrap(provers, problems, timeout_seconds: 60)
results = AtpBenchmarkRunner.run_benchmark(plan)
```

or direct one-liners:

```elixir
results = AtpBenchmarkRunner.local_benchmark([:vampire, :eprover], problems)
result  = AtpBenchmarkRunner.local_run_single(:vampire, problems |> hd())
```

`bootstrap/3` with `mode: :local` (the default) builds a `Run` plan; passing
`timeout_seconds:` sets the per-problem limit. Local execution uses, in
priority order: an existing local Apptainer SIF, then Docker, then the native
executable. Provers that need a pre-parser (e.g. `cvc5` via `input: :smt2`,
`lash` via `input: :thf`) are handled automatically by the per-prover
`prover.exs` configuration.

### 3.5 Results table

```elixir
AtpBenchmarkRunner.results_table(results)
AtpBenchmarkRunner.results_table(results, memory: true)   # adds Memory (KB) column
```

### 3.6 Reports

```elixir
AtpBenchmarkRunner.print_report(results)          # summary report
AtpBenchmarkRunner.print_report_markdown(report)  # Markdown variant
AtpBenchmarkRunner.print_per_prover(results)
AtpBenchmarkRunner.print_per_problem(results)
AtpBenchmarkRunner.print_interesting(results)     # only noteworthy results
AtpBenchmarkRunner.print_verbose_report(results)  # per-result verbose lines
AtpBenchmarkRunner.print_explain_full(results)    # per-result explanations
AtpBenchmarkRunner.show_proof(results, :vampire, "GRP001-0.p")
AtpBenchmarkRunner.print_raw_output(results, :vampire, "GRP001-0.p")
```

`print_*` helpers `IO.puts` directly so notebooks need only the single call;
the non-printing variants (`explain_full/1`, `diff_markdown/1`, ...) return
strings for programmatic use.

### 3.7 Visualizations

```elixir
AtpBenchmarkRunner.visualize(results)          # solved/unsolved overview
AtpBenchmarkRunner.visualize_proof(results)    # proof renderings
```

### 3.8 Persistence

```elixir
paths = AtpBenchmarkRunner.persist_run!(run, results, report)
# => %{run_path:, results_path:, report_path:}

AtpBenchmarkRunner.Store.list_runs()                 # saved run manifests
AtpBenchmarkRunner.Store.load_run!(path)
AtpBenchmarkRunner.Store.load_results!(path)
AtpBenchmarkRunner.save_to_db!(run, results, report) # persist + record in local DB
```

`persist_run!/4` saves the run manifest, parsed results and report in one call.

### 3.9 Comparison

```elixir
diff = AtpBenchmarkRunner.compare_runs(left, right)
AtpBenchmarkRunner.print_diff(diff)      # IO.puts the Markdown diff
```

Each side of `compare_runs/3` may be a list of results, a path to a saved
`.results.json` artifact, or a run id (loaded from the local DB). The diff
summarizes new solves and regressions.

---

## 4. HPC workflow (FAU Helma/Fritz)

### 4.1 Session

The HPC session comes from `hpc_connect` (bootstrap/connection_setup). Enable
the steady SSH connection to multiplex all commands over one persistent shell:

```elixir
boot = HpcConnect.bootstrap(mode: :local, cluster: :alex, env_file: "../.env",
                            steady_connection: true)
session = boot.session
```

`steady_connection: true` is equivalent to `HPC_CONNECT_STEADY_CONNECTION=true`
in `.env`; tune `HPC_CONNECT_STEADY_TIMEOUT_SECONDS` (default `30`). See the
hpc_connect manual for details.

### 4.2 Build HPC images

```elixir
AtpBenchmarkRunner.upload_prover_definitions!(session, AtpBenchmarkRunner.Provers.all())
AtpBenchmarkRunner.build_prover_images!(session, AtpBenchmarkRunner.Provers.all())
AtpBenchmarkRunner.build_prover_images!(session, provers, force: true)
AtpBenchmarkRunner.smoke_validate_images!(session, provers)
```

`build_prover_images!/3` uploads each prover's `apptainer.def` and builds the
remote `.sif`. `force: true` (alias for `force_rebuild: true`) rebuilds even if
the `.sif` exists, using `apptainer build --force --ignore-fakeroot-command`.

### 4.3 Run

```elixir
plan =
	AtpBenchmarkRunner.bootstrap(session, provers, problems,
		mode: :hpc,
		hpc_mode: :single_node,        # :single_node | :multi_node
		single_node_mode: :sequential, # :sequential | :parallel
		node_size: :full,              # :full | :half
		partition: "cpu",
		max_parallel_jobs: 4,
		timeout_seconds: 60,
		prepare_images: true           # auto-build missing SIFs
	)

results = AtpBenchmarkRunner.run_benchmark(plan)   # polls until done
```

HPC execution uses SLURM array jobs; results include peak RSS (KB), so the HPC
notebook calls `results_table(results, memory: true)`. For manual job control:

```elixir
AtpBenchmarkRunner.monitor(session, plan)   # poll progress
AtpBenchmarkRunner.status(session, plan)    # SLURM job rows
AtpBenchmarkRunner.cancel(session, plan)    # cancel all run jobs
```

`node_size: :full` requests `--exclusive` with all node CPUs; `:half` requests
half the node. CPU counts are auto-detected per cluster (Helma: 384/192,
Fritz: 72/36, spr\*: 104/52).

---

## 5. Configuration

| Env var                                     | Default                               | Purpose                                                                      |
| ------------------------------------------- | ------------------------------------- | ---------------------------------------------------------------------------- |
| `ATP_BENCHMARK_RUNNER_STORE_DIR`            | `~/.cache/atp_benchmark_runner/store` | run manifests, results, reports (fallback: `ATP_BENCHMARK_RUNNER_CACHE_DIR`) |
| `TPTP_ROOT` / `TPTP_DIR`                    | `./tmp/tptp`                          | local TPTP problem root                                                      |
| `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR`          | `./tmp/smt_converted`                 | TPTP→SMT converted files (`cvc5`)                                            |
| `ATP_BENCHMARK_RUNNER_SMT_THF_DIR`          | `./tmp/thf_converted`                 | TPTP→THF converted files (`lash`)                                            |
| `ATP_BENCHMARK_RUNNER_SIF_DIR`              | `./tmp/singularity_images`            | local Apptainer `.sif` images                                                |
| `ATP_BENCHMARK_RUNNER_BUNDLED_EXAMPLES_DIR` | `./tmp/tptp_examples`                 | bundled TPTP examples copy                                                   |
| `HPC_CONNECT_STEADY_CONNECTION`             | —                                     | HPC: persistent steady SSH shell (via hpc_connect)                           |
| `HPC_CONNECT_STEADY_TIMEOUT_SECONDS`        | `30`                                  | HPC: per-command ssh connect timeout                                         |

`setup_local/1` and `load_env!/1` cover the common cases; the table above shows
the raw overrides.

---

## 6. Adding a new prover

See the handbook [`adding_custom_provers_guide.md`](./adding_custom_provers_guide.md).
The short version:

1. Copy `priv/provers/_template/` to `priv/provers/<name>/`.
2. Fill in `prover.exs` (name, `command_template`, `input`, `parser`, ...),
   `Containerfile` and `apptainer.def`.
3. Recompile so the new `priv` dir is copied, then re-run
   `AtpBenchmarkRunner.Provers.validate()`.

The `prover.exs` schema is strict — unknown keys are rejected so mistakes are
caught at load time, not silently ignored.

---

## 7. Troubleshooting

| Symptom                                                                          | Cause / fix                                                                                                                     |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `build_local_images!` returns `{:error, name, "executable apptainer not found"}` | Apptainer is not installed on PATH; use `backend: :docker` or install Apptainer                                                 |
| Docker build fails even though the image exists                                  | Docker not running, or a stale image — use `force: true` (adds `--no-cache`)                                                    |
| Local run ignores my freshly built image                                         | Local execution prefers an existing SIF, then Docker, then native; build with the matching backend                              |
| HPC build fails on an existing `.sif`                                            | `build_prover_images!(..., force: true)` (remote `--force --ignore-fakeroot-command`)                                           |
| New prover not discovered                                                        | `prover.exs` missing/malformed, or the `priv` dir was not copied after adding it — run `Provers.validate()` and check the guide |
| TPTP-to-SMT/THF conversion errors                                                | Check `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` / `..._SMT_THF_DIR` are writable; the parser is selected per prover via `prover.exs`   |
| HPC commands are slow / handshake per command                                    | Enable the steady SSH connection (see §4.1)                                                                                     |
