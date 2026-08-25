# AtpBenchmarkRunner Command Cheat Sheet

One-call helpers for the common local and HPC benchmark workflows.
Full explanations live in [`atp_br_manual.md`](./atp_br_manual.md).

---

## Setup (Livebook)

```elixir
Mix.install([
  {:atp_benchmark_runner, path: "../atp_benchmark_runner"},
  {:hpc_connect, path: "../../item_15_Elixir_HPC_Connect_Library/hpc_connect"}
])

AtpBenchmarkRunner.setup_local(tmp_root: Path.expand("./tmp", __DIR__))
AtpBenchmarkRunner.load_env!("../.env")       # HPC + runner env vars
```

---

## Prover registry

```elixir
AtpBenchmarkRunner.Provers.all()             # all discovered prover structs
AtpBenchmarkRunner.Provers.names()           # prover names (from prover.exs files)
AtpBenchmarkRunner.Provers.fetch!(:vampire)  # single prover (atom or name string)
AtpBenchmarkRunner.built_in_provers()        # bundled prover structs
AtpBenchmarkRunner.Provers.validate()        # list of registry issues ([] = ok)
```

---

## Image status

```elixir
AtpBenchmarkRunner.LocalRunner.image_status_summary()   # returns string
AtpBenchmarkRunner.LocalRunner.print_image_status_summary()  # IO.puts it
AtpBenchmarkRunner.LocalRunner.detect_available()       # what tools are present
```

## Build local images

```elixir
AtpBenchmarkRunner.build_local_images!(:all)
AtpBenchmarkRunner.build_local_images!([:vampire, :eprover])
AtpBenchmarkRunner.build_local_images!(:all, backend: :docker)     # :auto | :docker | :apptainer
AtpBenchmarkRunner.build_local_images!(:all, force: true)          # rebuild even if present
```

Returns `[{:ok, name} | {:error, name, reason}, ...]`.

## Build HPC images (Apptainer)

```elixir
AtpBenchmarkRunner.upload_prover_definitions!(session, AtpBenchmarkRunner.Provers.all())
AtpBenchmarkRunner.build_prover_images!(session, AtpBenchmarkRunner.Provers.all())
AtpBenchmarkRunner.build_prover_images!(session, provers, force: true)  # remote --force rebuild
AtpBenchmarkRunner.smoke_validate_images!(session, provers)             # smoke-test the SIFs
```

---

## Problems

```elixir
AtpBenchmarkRunner.download_tptp_problems!(["GRP001-0.p", "ANA002-4.p"])  # => {problems, warnings}
AtpBenchmarkRunner.select_problems(["GRP001-0.p"])                        # by name
AtpBenchmarkRunner.select_problems(rating_max: 0.1, limit: 15)            # by filter
AtpBenchmarkRunner.load_tptp_problems()                                   # local TPTP_ROOT
```

---

## Local run

```elixir
plan = AtpBenchmarkRunner.bootstrap(provers, problems, timeout_seconds: 60)
results = AtpBenchmarkRunner.run_benchmark(plan)
```

or direct:

```elixir
results = AtpBenchmarkRunner.local_benchmark([:vampire, :eprover], problems)
result  = AtpBenchmarkRunner.local_run_single(:vampire, problem)
```

---

## HPC run

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
		prepare_images: true
	)

results = AtpBenchmarkRunner.run_benchmark(plan)   # polls until done
AtpBenchmarkRunner.monitor(session, plan)          # poll progress manually
AtpBenchmarkRunner.status(session, plan)           # SLURM job rows
AtpBenchmarkRunner.cancel(session, plan)           # cancel all run jobs
```

---

## Results table

```elixir
AtpBenchmarkRunner.results_table(results)
AtpBenchmarkRunner.results_table(results, memory: true)  # adds Memory (KB) column (HPC)
```

---

## Reports

```elixir
AtpBenchmarkRunner.print_report(results)            # summary report
AtpBenchmarkRunner.print_report_markdown(report)    # Markdown variant
AtpBenchmarkRunner.print_per_prover(results)
AtpBenchmarkRunner.print_per_problem(results)
AtpBenchmarkRunner.print_interesting(results)       # only noteworthy results
AtpBenchmarkRunner.print_verbose_report(results)    # per-result verbose lines
AtpBenchmarkRunner.print_explain_full(results)      # per-result explanations
AtpBenchmarkRunner.explain_full(results)            # ... as a list of strings
AtpBenchmarkRunner.show_proof(results, :vampire, "GRP001-0.p")
AtpBenchmarkRunner.print_raw_output(results, :vampire, "GRP001-0.p")
```

---

## Visualizations

```elixir
AtpBenchmarkRunner.visualize(results)          # solved/unsolved overview
AtpBenchmarkRunner.visualize_proof(results)    # proof renderings
```

---

## Persistence

```elixir
AtpBenchmarkRunner.persist_run!(run, results, report)
# => %{run_path:, results_path:, report_path:}

AtpBenchmarkRunner.Store.list_runs()                 # saved run manifests
AtpBenchmarkRunner.Store.load_run!(path)             # re-load a run
AtpBenchmarkRunner.Store.load_results!(path)         # re-load results
AtpBenchmarkRunner.save_to_db!(run, results, report) # persist + record in local DB
```

---

## Comparison

```elixir
diff = AtpBenchmarkRunner.compare_runs(left, right)   # sides: results | .results.json path | run id
AtpBenchmarkRunner.print_diff(diff)                   # Markdown diff
AtpBenchmarkRunner.diff_markdown(diff)                # ... as a string
```

---

## Adding a prover

See [`adding_custom_provers_guide.md`](./adding_custom_provers_guide.md).
Each prover lives in `priv/provers/<name>/` with a `prover.exs` spec, a
`Containerfile` (local Docker) and an `apptainer.def` (HPC SIF). The registry
discovers them automatically; the `_template/` directory is a ready scaffold.
