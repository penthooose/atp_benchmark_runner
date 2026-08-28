# ATP Benchmark Runner

Elixir library for StarExec-style ATP benchmark runs from local scripts or
Livebook. It handles benchmark orchestration and reporting; FAU HPC access is
delegated to the `hpc_connect` library ([penthooose/hpc_connect](<[https:\](https://github.com/penthooose/hpc_connect)>)).

## Scope

- Define runs from TPTP problem names or paths
- Pick problems by bare filename (`"GRP001-0.p"`) or directory hint
  (`"Problems/REL/REL001+0.p"`)
- Nine built-in provers, each declared in `priv/provers/<name>/prover.exs`:
  AISE Tableaux, ShotTx, Vampire, E-Prover, CVC5, Leo-III, LEO-II,
  Zipperposition, Lash
- Local runs via Docker or Apptainer images from each prover's `Containerfile`;
  HPC runs via `.sif` images built from `apptainer.def`
- HPC: sync problems, submit/query/cancel SLURM jobs, collect results
- Parse SZS statuses, aggregate reports, compare runs across sessions
- Persist runs, results, and reports as JSON
- Livebook: setup overlay, dashboard, monitor/report panels, Mermaid diagrams
- Optional Oban scheduler and webhook/email summaries

## Quick start

```elixir
# Point at your TPTP install, or let it default to ./tmp/tptp
System.put_env("TPTP_ROOT", "./tmp/tptp")

problems = AtpBenchmarkRunner.select_problems(["GRP001-0.p", "LAT001+0.p"])

plan = AtpBenchmarkRunner.bootstrap([:vampire, :eprover], problems,
  mode: :local, timeout_seconds: 120, auto_ensure_images: true
)

results = AtpBenchmarkRunner.run_benchmark(plan)
AtpBenchmarkRunner.results_table(results)
```

## Documentation

- [Manual](docs/atp_br_manual.md) - full reference: execution modes, config
  table, troubleshooting
- [Command cheat sheet](docs/commands_cheat_sheet.md)
- [Adding a prover](docs/adding_custom_provers_guide.md) - how the config-driven
  registry and image files work
- [Local benchmark notebook](examples/benchmark_local.livemd)
- [HPC benchmark notebook](examples/benchmark_hpc.livemd)

## TPTP problems

Problems come from three sources, in priority order:

1. **User examples** - files you drop into `<tptp_dir>/user_examples/`
2. **Bundled smoke examples** - 14 small CNF/FOF/THF problems shipped in
   `priv/tptp_examples/`
3. **Official archive** - optional full TPTP distribution or single downloads from tptp.org

Key config via env vars (or the Livebook setup overlay):

| Var                                         | Default                            | What                       |
| ------------------------------------------- | ---------------------------------- | -------------------------- |
| `TPTP_ROOT`                                 | `./tmp/tptp`                       | TPTP library root          |
| `ATP_BENCHMARK_RUNNER_USER_EXAMPLES_DIR`    | `<TPTP_ROOT>/user_examples`        | Your custom problem files  |
| `ATP_BENCHMARK_RUNNER_BUNDLED_EXAMPLES_DIR` | `./tmp/tptp_examples`              | Bundled smoke example copy |
| `ATP_BENCHMARK_RUNNER_STORE_DIR`            | `./tmp/atp_benchmark_runner_store` | Runs, results, reports     |

## Prover images

Each prover lives in `priv/provers/<name>/` with a `prover.exs` spec (name,
command, input/parser hooks, container refs), a local `Containerfile`, and an
HPC `apptainer.def`. The registry discovers provers by scanning that directory,
so adding one is a matter of dropping a folder. See
[docs/adding_custom_provers_guide.md](docs/adding_custom_provers_guide.md).

The `apptainer.def` files stay in this project and are never copied into the
`hpc_connect` dependency. The runner uploads them and builds `.sif` images
through the generic `hpc_connect` build workflow
(`AtpBenchmarkRunner.build_prover_images!/3`).

## Local vs HPC

- **Local** - run the same images with Docker or Apptainer on your machine.
  See [examples/benchmark_local.livemd](examples/benchmark_local.livemd).
- **HPC** - bootstrap an `hpc_connect` session, sync problems, build `.sif`
  images, submit, and collect. See
  [examples/benchmark_hpc.livemd](examples/benchmark_hpc.livemd) and the
  [cheat sheet's HPC-run section](docs/commands_cheat_sheet.md#hpc-run).

## Livebook

The notebooks above are the intended entry point. There is also a setup overlay
(`AtpBenchmarkRunner.prepare_livebook_setup/1`) that pre-fills every env var
from `.env`/`.env.example`, plus a dashboard
(`AtpBenchmarkRunner.livebook_dashboard/1`) and monitor/report panels.
