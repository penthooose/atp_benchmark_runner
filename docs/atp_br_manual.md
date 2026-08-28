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

> **Keep steady ON.** The shipped atp `.env` sets
> `HPC_CONNECT_STEADY_CONNECTION=true`. Without it, every benchmark sync/submit
> step opens dozens of fresh SSH/SCP handshakes through the `csnhr` jump
> gateway, which throttles after too many requests (`Connection refused`) and
> stalls the run with no job created. With steady on, `connect!`/`SSH.exec`
> multiplex over one persistent shell that self-heals: it detects a dead shell
> (registry `Process.alive?` + port-level `ensure_port`) and transparently
> reopens/restarts it on the next command — including across Livebook cells,
> because the server is started unlinked and registered in an ETS keeper that
> survives short-lived callers.
>
> **Problem uploads also ride the steady shell (no scp).** `TPTPSync` uploads
> problem files and their SMT/THF conversions via `RemoteFiles.upload_file!`
> — base64 streamed over the persistent shell (`printf %s <b64> | base64 -d`),
> chunked for large files, CRLF→LF normalized. This was switched away from
> `scp` because **scp cannot multiplex over the steady `bash -s` shell** — each
> `scp` was a fresh connection that bypassed steady and re-tripped the gateway
> rate limiter (the `transient scp error ... Connection refused` spam). With
> the switch, a 14-problem sync makes **zero** fresh connections (verified:
> upload ~33 ms, no throttling).

**Connection retry robustness.** SSH handshakes to the gateway (`csnhr`) can
fail transiently with `Connection refused` / `Connection timed out` — typically
gateway throttling after many rapid requests. Two complementary mechanisms,
both configurable in `.env`:

- `HPC_CONNECT_RETRY_FOREVER=true` — never give up on transient SSH connection
  errors; retry with exponential backoff (1 s → 2 s → 4 s → … capped at 60 s)
  until the call succeeds. This is the per-session opt-in; it applies to the
  steady shell, default `SSH.exec/exec!` calls, the top-level
  `connect!`/`run_command_with_retry!` path, **and** `SSH.upload!` (SCP), which
  now honors the same flag instead of dying after 3 fixed retries. Off by
  default so fail-fast callers (e.g. the hpc_connect bootstrap smoke tests)
  still give up quickly.
- `HPC_CONNECT_STEADY_CONNECTION=true` — multiplex commands over one persistent
  shell, which avoids the per-command handshake that triggers the throttling in
  the first place. Combined with retry-forever this is fully self-healing.

The `.env` the notebook loads is authoritative for its session: the notebook
loads the _atp_benchmark_runner_ `.env` (via `load_env!("../.env")`), **not** the
hpc_connect `.env`. So both flags must be set in the atp `.env` to affect a
notebook session. `retry_forever` can also be forced per call, e.g.
`HpcConnect.connect!(session, retry_forever: true)` or
`HpcConnect.SSH.exec(session, cmd, retry_forever: true)`.

**Validated 2026-08-28** via `mix run testing/submit_smoke.exs` (steady on,
retry-forever on): the persistent shell establishment hit 7 transient
`Connection refused` failures from gateway throttling and retried until it
worked, then `sbatch` created job `794076` (PENDING in `squeue`) and `scancel`
cleaned it up.

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

By default the builds run directly on the login node
(`build_on_login_node: true`). Set `build_on_login_node: false` to run them on
a compute node instead — all selected images are then chained into a **single
sbatch job** (built one after the other) rather than one job per prover.

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

When the run starts, the runner prints the run's ID and saves the run manifest
to the store immediately (`Run ID: <id>` / `[runner] Run <id> starting —
manifest: <path>`). So even if the run fails before any job is submitted, the
run_id is known and the plan is on disk.

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

### 4.3b Execution modes and resource strategy

The mode table and the ready-to-paste plan variants for each combination:

| Mode                             | `hpc_mode`     | `single_node_mode` | Resource allocation                                                  |
| -------------------------------- | -------------- | ------------------ | -------------------------------------------------------------------- |
| Single-node sequential (default) | `:single_node` | `:sequential`      | All provers share 1 node. Tasks one at a time; each gets node CPUs.  |
| Single-node parallel             | `:single_node` | `:parallel`        | All provers share 1 node. Tasks run concurrently (≤ `max_parallel`). |
| Multi-node (prover per node)     | `:multi_node`  | —                  | Each prover gets its own node.                                       |

`node_size` controls CPU allocation (`--exclusive` for `:full`, half the node
for `:half`).

```elixir
# Single-node sequential, half node
plan_half =
	AtpBenchmarkRunner.bootstrap(session, provers, problems,
		mode: :hpc,
		hpc_mode: :single_node,
		single_node_mode: :sequential,
		node_size: :half,
		timeout_seconds: 60,
		wait_for_completion: false,
		prepare_images: false
	)

# Single-node parallel, full node (≤ max_parallel_jobs concurrent tasks)
plan_parallel =
	AtpBenchmarkRunner.bootstrap(session, provers, problems,
		mode: :hpc,
		hpc_mode: :single_node,
		single_node_mode: :parallel,
		max_parallel_jobs: 4,
		timeout_seconds: 60,
		wait_for_completion: false,
		prepare_images: false
	)

# Multi-node: each prover gets its own node (default full)
plan_multi =
	AtpBenchmarkRunner.bootstrap(session, provers, problems,
		mode: :hpc,
		hpc_mode: :multi_node,
		timeout_seconds: 60,
		wait_for_completion: false,
		prepare_images: false
	)
```

### 4.4 Resume: fetch results without re-running

The run manifest (`*.run.json`) is persisted in the store **the moment the run
starts** — and the run_id is printed as part of the start banner — so the last
run is always identifiable and recoverable even if the notebook cell crashes,
or the SSH connection dies while fetching.

- **Collection never gives up.** Result fetching (`Results.collect`) runs with
  `collect_retry_forever: true`: on transient SSH failures (`Connection
refused` / `closed` / `timed out`, scp status 255) or while result files are
  still missing, it retries with exponential backoff (10 s → 60 s cap) **until
  the results arrive** instead of failing the run.
- **Resume a specific run** — by run id (the id printed at run start) or a
  `%Run{}` plan / manifest:

```elixir
results = AtpBenchmarkRunner.collect_hpc_results!(session, "run_20260827_155553_1028")

# equivalent:
run = AtpBenchmarkRunner.Store.load_run_by_id!("run_20260827_155553_1028")
AtpBenchmarkRunner.collect_hpc_results!(session, run)
```

- **Fetch only the last run's results** — no re-submission, no re-sync:

```elixir
results = AtpBenchmarkRunner.collect_last_hpc_results!(session)
```

`collect_last_hpc_results!/2` loads the newest `*.run.json` that was actually
**submitted** (has SLURM job ids) and collects it (persisting the results).
Manifests persisted at run start but that never reached `sbatch` (e.g. SSH
refused during problem sync) are skipped with a clear error.

**Remote-cluster fallback:** if a run id is not in the local store (or no
submitted local manifest exists), both resume functions look the run up on the
cluster — under `<remote_root>/run_results/<run_id>` (current layout) or
`<remote_root>/<run_id>` (legacy) — and fetch the results directly. So HPC runs
that were never persisted locally (submitted before manifest persistence, or
after a store wipe) are still resumable by run id. Runs fetched this way use
finite retries (they are already finished). `ArgumentError` is raised only when
the run exists neither locally nor on the cluster (e.g. it never reached
`sbatch`).

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
| `HPC_CONNECT_RETRY_FOREVER`                 | `false`                               | HPC: retry transient SSH connection errors forever (backoff up to 60 s)      |

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

| Symptom                                                                           | Cause / fix                                                                                                                                                             |
| --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build_local_images!` returns `{:error, name, "executable apptainer not found"}`  | Apptainer is not installed on PATH; use `backend: :docker` or install Apptainer                                                                                         |
| Docker build fails even though the image exists                                   | Docker not running, or a stale image — use `force: true` (adds `--no-cache`)                                                                                            |
| Local run ignores my freshly built image                                          | Local execution prefers an existing SIF, then Docker, then native; build with the matching backend                                                                      |
| HPC build fails on an existing `.sif`                                             | `build_prover_images!(..., force: true)` (remote `--force --ignore-fakeroot-command`)                                                                                   |
| New prover not discovered                                                         | `prover.exs` missing/malformed, or the `priv` dir was not copied after adding it — run `Provers.validate()` and check the guide                                         |
| TPTP-to-SMT/THF conversion errors                                                 | Check `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` / `..._SMT_THF_DIR` are writable; the parser is selected per prover via `prover.exs`                                           |
| HPC commands are slow / handshake per command                                     | Enable the steady SSH connection (see §4.1)                                                                                                                             |
| `Connection refused` / `Connection timed out` during connect or exec              | Gateway throttling after too many SSH requests. Set `HPC_CONNECT_RETRY_FOREVER=true` in the atp `.env` (authoritative for the notebook) and/or enable steady (see §4.1) |
| `Benchmark failed: scp failed (status 255) ... Connection refused` while fetching | Transient SSH drop during result fetch; collection now retries until success. If the run failed anyway, resume with `collect_last_hpc_results!(session)` (see §4.4)     |
