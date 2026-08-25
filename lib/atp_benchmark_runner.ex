defmodule AtpBenchmarkRunner do
  @moduledoc """
  High-level API for ATP benchmark runs.

  The library is designed to be imported into Livebook, local scripts, or IEx.
  Cluster interaction is delegated to the local `hpc_connect` project so this
  package stays focused on benchmark domain logic and reporting.
  """

  alias AtpBenchmarkRunner.{
    Compare,
    Config,
    Notification,
    Problem,
    Prover,
    Provers,
    Report,
    Result,
    Run,
    Store,
    TPTP,
    Visualize,
    Workflow
  }

  alias AtpBenchmarkRunner.{
    LocalRunner,
    HPC.ImageSmokeTest,
    HPC.Images,
    HPC.Results,
    HPC.Submitter,
    HPC.TPTPSync
  }

  alias AtpBenchmarkRunner.HPC.Config, as: HPCConfig

  @doc """
  Store dir for run manifests, results and reports.

  Configurable via `ATP_BENCHMARK_RUNNER_STORE_DIR` env var or `:dir` option.
  See `AtpBenchmarkRunner.Config.store_dir/1` for resolution order.
  """
  @spec store_dir(keyword()) :: binary()
  def store_dir(opts \\ []), do: Config.store_dir(opts)

  @doc """
  TPTP root for local problem files.

  Configure via `TPTP_ROOT` env var, or `:tptp_dir` / `:root_dir` option.
  See `AtpBenchmarkRunner.Config.tptp_dir/1`.
  """
  @spec tptp_dir(keyword()) :: binary()
  def tptp_dir(opts \\ []), do: Config.tptp_dir(opts)

  @doc """
  Redirects all storage into `./tmp/`, keeping the workspace self-contained.

  Call right after Mix.install in Livebook:

      AtpBenchmarkRunner.setup_local(tmp_root: Path.expand("./tmp", __DIR__))

  Sets `ATP_BENCHMARK_RUNNER_STORE_DIR`, `TPTP_ROOT`, and
  `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` under `tmp_root`. Without this,
  everything falls back to `~/.cache/atp_benchmark_runner`.
  """
  @spec setup_local(keyword()) :: :ok
  def setup_local(opts \\ []) do
    tmp_root =
      opts
      |> Keyword.get(:tmp_root, "./tmp")
      |> Config.expand_path()

    System.put_env("ATP_BENCHMARK_RUNNER_STORE_DIR", Path.join(tmp_root, "store"))
    System.put_env("TPTP_ROOT", Path.join(tmp_root, "tptp"))
    System.put_env("ATP_BENCHMARK_RUNNER_SMT_TMP_DIR", Path.join(tmp_root, "smt_converted"))
    System.put_env("ATP_BENCHMARK_RUNNER_SMT_THF_DIR", Path.join(tmp_root, "thf_converted"))
    :ok
  end

  @doc """
  Converts a TPTP file to SMT-LIB string.

  Needed for provers like CVC5 that don't natively parse TPTP.

      smt = AtpBenchmarkRunner.convert_tptp_to_smt!("path/to/problem.p")
  """
  @spec convert_tptp_to_smt!(binary()) :: binary()
  def convert_tptp_to_smt!(path) when is_binary(path),
    do: AtpBenchmarkRunner.TPTPToSMT.convert_file!(path)

  @doc """
  Converts a TPTP problem file to SMT-LIB and writes it to the configured temp directory.

  Returns the path to the written `.smt2` file.

  The temp directory is resolved via `Config.smt_tmpr/1` and can be
  configured with `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` env var.
  """
  @spec convert_tptp_to_smt_path!(binary(), keyword()) :: binary()
  def convert_tptp_to_smt_path!(path, opts \\ []) when is_binary(path),
    do: AtpBenchmarkRunner.TPTPToSMT.convert_file_to_path!(path, opts)

  @doc """
  Creates a benchmark run manifest.
  """
  @spec new_run(keyword() | map()) :: Run.t()
  def new_run(opts \\ []), do: Run.new(opts)

  @doc """
  Loads a `.env` file and applies its `KEY=VALUE` pairs to the OS environment
  (so `Config.get/2` and `hpc_connect` pick them up). Returns the parsed map.

      AtpBenchmarkRunner.load_env!("path/to/.env")
  """
  @spec load_env!(binary()) :: map()
  def load_env!(path) do
    env = HpcConnect.load_env_file(path)
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)
    env
  end

  @doc """
  Persists a run manifest, its parsed results, and its report in one call.

  Returns `%{run_path:, results_path:, report_path:}`.
  """
  @spec persist_run!(Run.t(), [Result.t()], map(), keyword()) :: map()
  def persist_run!(run, results, report, opts \\ []) do
    %{
      run_path: save_run!(run, opts),
      results_path: save_results!(run, results, opts),
      report_path: save_report!(run, report, opts)
    }
  end

  @doc """
  Returns the built-in prover registry.
  """
  @spec built_in_provers() :: [Prover.t()]
  def built_in_provers, do: Prover.builtins()

  @doc """
  Returns integration/container research notes for supported provers.
  """
  @spec prover_research_summary() :: [map()]
  def prover_research_summary, do: Provers.research_summary()

  @doc """
  Returns a local Apptainer image preparation plan for the selected provers.
  """
  @spec image_plan([Prover.t()]) :: [map()]
  def image_plan(provers), do: Images.plan(provers)

  @doc """
  Returns a session-aware plan for uploading/building prover Apptainer images.
  """
  @spec image_build_plan(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def image_build_plan(session, provers, opts \\ []),
    do: Images.build_plan(session, provers, opts)

  @doc """
  Uploads selected prover definition files through `hpc_connect`.
  """
  @spec upload_prover_definitions!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def upload_prover_definitions!(session, provers, opts \\ []),
    do: Images.upload_definitions!(session, provers, opts)

  @doc """
  Builds selected prover Apptainer images through `hpc_connect`.

  Uploads each prover's `apptainer.def` and builds the remote `.sif`. Set
  `force: true` (alias for `force_rebuild: true`) to rebuild even if the `.sif`
  already exists — the remote build then uses
  `apptainer build --force --ignore-fakeroot-command`.
  """
  @spec build_prover_images!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def build_prover_images!(session, provers, opts \\ []) do
    opts =
      if Keyword.get(opts, :force, false) do
        Keyword.put_new(opts, :force_rebuild, true)
      else
        opts
      end

    Images.build_all!(session, provers, opts)
  end

  @doc """
  Builds (or pulls) local images for all given provers in one call.

  `backend` selects the local build tool: `:auto` (default — Docker if
  available, else Apptainer), `:docker`, or `:apptainer`. Set `force: true`
  to rebuild every image even if already present. `provers` may be `:all`.
  Returns a list of `{:ok, name}` / `{:error, name, reason}`.

      AtpBenchmarkRunner.build_local_images!(:all)
      AtpBenchmarkRunner.build_local_images!([:vampire, :eprover],
        force: true, backend: :apptainer)
  """
  @spec build_local_images!(atom() | [atom() | binary()], keyword()) :: list()
  def build_local_images!(provers, opts \\ []), do: LocalRunner.build_images!(provers, opts)

  @doc """
  Smoke-validates selected prover images against bundled TPTP examples.
  """
  @spec smoke_validate_images!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: [map()]
  def smoke_validate_images!(session, provers, opts \\ []),
    do: ImageSmokeTest.validate!(session, provers, opts)

  @doc """
  Returns official TPTP archive choices known to the runner.
  """
  @spec tptp_archives() :: [AtpBenchmarkRunner.TPTP.Archive.t()]
  def tptp_archives, do: TPTP.available_archives()

  @doc """
  Installs tiny bundled TPTP smoke examples into the configured TPTP root.
  """
  @spec install_tptp_examples!(keyword()) :: [binary()]
  def install_tptp_examples!(opts \\ []), do: TPTP.install_examples!(opts)

  @doc """
  Downloads and extracts the official TPTP archive selected in options.
  """
  @spec ensure_tptp_archive(keyword()) :: {:ok, binary()} | {:error, term()}
  def ensure_tptp_archive(opts \\ []), do: TPTP.ensure_archive(opts)

  @doc """
  Downloads only the named TPTP problems instead of the full archive.

  Problems that exist in the current official release are fetched from the
  TPTP SeeTPTP CGI and written to their archive-consistent path
  `<tptp_root>/Problems/<DOMAIN>/<NAME>.p`. Names the server does not have
  (e.g. bundled smoke examples that are not real TPTP problems) are looked up in
  the local sources by default — bundled examples from `priv/tptp_examples` are
  auto-copied into the bundled tmp dir and returned from there, so they are
  usable without ever being written into `<tptp_root>/Problems/`.

  Returns `{:ok, problems, warnings}` where `warnings` is a list of
  `%{name: binary(), reason: term()}` maps (only names found in neither the
  server nor any local source).

  Options: `:root_dir`, `:force`, `:bundled_fallback` (set `false` for strict
  server-only; missing names then warn with `{:not_found, name}`).

      {:ok, problems, warnings} =
        AtpBenchmarkRunner.download_tptp_problems(["GRP001-1.p", "LAT001-1.p"])
  """
  @spec download_tptp_problems([binary()], keyword()) ::
          {:ok, [AtpBenchmarkRunner.Problem.t()], [%{name: binary(), reason: term()}]}
  def download_tptp_problems(names, opts \\ []), do: TPTP.download_problems(names, opts)

  @doc """
  Like `download_tptp_problems/2` but returns `{problems, warnings}` directly
  for Livebook/manual use. Best-effort — missing names become warnings, never an
  exception.

      {problems, warnings} = AtpBenchmarkRunner.download_tptp_problems!(names)
  """
  @spec download_tptp_problems!([binary()], keyword()) ::
          {[AtpBenchmarkRunner.Problem.t()], [%{name: binary(), reason: term()}]}
  def download_tptp_problems!(names, opts \\ []) do
    case TPTP.download_problems(names, opts) do
      {:ok, problems, warnings} -> {problems, warnings}
    end
  end

  @doc """
  Loads local TPTP files into benchmark problem structs.
  """
  @spec load_tptp_problems(keyword()) :: [AtpBenchmarkRunner.Problem.t()]
  def load_tptp_problems(opts \\ []), do: TPTP.load_problem_set(opts)

  @doc """
  Select benchmark problems by name or filter.

      AtpBenchmarkRunner.select_problems(["GRP001-0.p", "ANA002-4.p"])
      AtpBenchmarkRunner.select_problems(rating_max: 0.1, limit: 15)

  See `AtpBenchmarkRunner.TPTP.select/1` for all options.
  """
  @spec select_problems(keyword() | [binary()]) :: [AtpBenchmarkRunner.Problem.t()]
  def select_problems(opts \\ []), do: TPTP.select(opts)

  @doc """
  Resolves a TPTP problem name to a file path across multiple locations.
  """
  @spec resolve_tptp_name(binary(), keyword()) :: binary() | nil
  def resolve_tptp_name(name, opts \\ []), do: TPTP.resolve_problem_name(name, opts)

  @doc """
  Builds a plan for syncing local TPTP files to HPC storage.
  """
  @spec tptp_sync_plan(HpcConnect.Session.t(), [AtpBenchmarkRunner.Problem.t()], keyword()) ::
          map()
  def tptp_sync_plan(session, problems, opts \\ []), do: TPTPSync.plan(session, problems, opts)

  @doc """
  Syncs local TPTP files to HPC storage and returns remote-path problems.
  """
  @spec sync_tptp_problems!(HpcConnect.Session.t(), [AtpBenchmarkRunner.Problem.t()], keyword()) ::
          [AtpBenchmarkRunner.Problem.t()]
  def sync_tptp_problems!(session, problems, opts \\ []),
    do: TPTPSync.sync_problem_set!(session, problems, opts)

  @doc """
  Builds a Kubernetes Job manifest map for a single prover/problem execution.
  """
  @spec kubernetes_job(Prover.t() | atom() | binary(), binary(), keyword()) :: map()
  def kubernetes_job(prover, problem_path, opts \\ []),
    do: AtpBenchmarkRunner.Prover.Kubernetes.job_manifest(prover, problem_path, opts)

  @doc """
  Generates a dry-run submission plan for inspection.
  """
  @spec plan(HpcConnect.Session.t(), Run.t(), keyword()) :: map()
  def plan(session, %Run{} = run, opts \\ []), do: Submitter.plan(run, session, opts)

  @doc """
  Submits a benchmark run via `hpc_connect`.
  """
  @spec submit(HpcConnect.Session.t(), Run.t(), keyword()) :: Run.t() | map()
  def submit(session, %Run{} = run, opts \\ []), do: Submitter.submit_run(session, run, opts)

  @doc """
  Returns SLURM status rows for jobs belonging to a submitted run.
  """
  @spec status(HpcConnect.Session.t(), Run.t(), keyword()) :: [map()]
  def status(session, %Run{} = run, opts \\ []), do: Submitter.status(session, run, opts)

  @doc """
  Polls submitted jobs and remote result directories for run progress.
  """
  @spec monitor(HpcConnect.Session.t(), Run.t(), keyword()) :: map()
  def monitor(session, %Run{} = run, opts \\ []),
    do: AtpBenchmarkRunner.Monitor.poll(session, run, opts)

  @doc """
  Cancels all submitted jobs belonging to a run.
  """
  @spec cancel(HpcConnect.Session.t(), Run.t(), keyword()) :: :ok
  def cancel(session, %Run{} = run, opts \\ []), do: Submitter.cancel_run(session, run, opts)

  @doc """
  Parses one prover output blob into a structured result.
  """
  @spec parse_result(atom() | binary(), binary(), binary(), keyword()) :: Result.t()
  def parse_result(prover, problem_id, output, opts \\ []),
    do: Result.from_output(prover, problem_id, output, opts)

  @doc """
  Collects remote result files and parses them.
  """
  @spec collect_results(HpcConnect.Session.t(), Run.t(), keyword()) :: [Result.t()]
  def collect_results(session, %Run{} = run, opts \\ []), do: Results.collect(session, run, opts)

  @doc """
  Collects remote cluster outputs, persists JSON/local-DB records, and generates a report.
  """
  @spec collect_store_report!(HpcConnect.Session.t(), Run.t(), keyword()) :: map()
  def collect_store_report!(session, %Run{} = run, opts \\ []),
    do: AtpBenchmarkRunner.Workflow.collect_store_report!(session, run, opts)

  @doc """
  Non-Oban one-shot nightly orchestration: load, sync, plan, and (optionally) submit.
  """
  @spec orchestrate_nightly(HpcConnect.Session.t(), keyword()) :: map()
  def orchestrate_nightly(session, opts \\ []),
    do: Workflow.orchestrate_nightly(session, opts)

  @doc """
  Collects, persists, reports, and renders the report in Livebook/Kino when available.
  """
  @spec collect_store_report_panel!(HpcConnect.Session.t(), Run.t(), keyword()) :: map() | term()
  def collect_store_report_panel!(session, %Run{} = run, opts \\ []),
    do: AtpBenchmarkRunner.Workflow.collect_store_report_panel!(session, run, opts)

  @doc """
  Aggregates benchmark results into comparison tables and interesting deltas.
  """
  @spec report([Result.t() | map()], Run.t() | nil, keyword()) :: map()
  def report(results, run \\ nil, opts \\ []), do: Report.summarize(results, run, opts)

  @doc """
  Creates a benchmark plan without running it. Use `run_benchmark/1` to execute.

  ## Modes

    * `:local` (default) — runs provers sequentially, each prover runs all problems
    * `:hpc` — runs provers in parallel on HPC via `hpc_connect`
      * `:single_node` (default) — all provers on one compute node
      * `:multi_node` — each prover on its own node

  ## Options

    * `:timeout_seconds` — per-problem limit (default: 60)
    * `:include_raw_output` — include full stdout (default: false)
    * `:auto_ensure_images` — pull/build missing images (default: false)
    * `:node_size` — CPU node allocation: `:full` (default) or `:half`
      * `:full` — `--exclusive` with all CPUs on the node
      * `:half` — no `--exclusive`, requests half the node's CPUs
      * CPU counts are auto-detected per cluster (Helma: 384/192, Fritz: 72/36, spr*: 104/52)
  """
  @spec bootstrap(
          HpcConnect.Session.t() | [Prover.t() | atom() | binary()],
          [Prover.t() | atom() | binary()] | [AtpBenchmarkRunner.Problem.t() | binary()],
          keyword()
        ) :: Run.t()
  def bootstrap(provers_or_session, problems_or_provers, opts \\ []) do
    mode = Keyword.get(opts, :mode, :local)

    case mode do
      :local ->
        provers = normalize_provers(provers_or_session)
        problems = normalize_problems(problems_or_provers)

        Run.new(
          title: Keyword.get(opts, :title, "Benchmark run"),
          problems: problems,
          provers: provers,
          problem_timeout_seconds: Keyword.get(opts, :timeout_seconds, 60),
          metadata: Map.new(opts) |> Map.put(:mode, mode)
        )

      :hpc ->
        raise ArgumentError,
              "HPC mode requires 3 arguments: session, provers, and problems. " <>
                "Call as: AtpBenchmarkRunner.bootstrap(session, provers, problems, mode: :hpc)"

      _ ->
        raise ArgumentError,
              "Unknown mode: #{inspect(mode)}. Expected :local or :hpc."
    end
  end

  @doc """
  Creates a benchmark plan for HPC execution with a session.

  Available HPC options (passed in the keyword list):

    * `:hpc_mode` — `:single_node` (default) or `:multi_node`
    * `:single_node_mode` — `:sequential` (default) or `:parallel`
    * `:node_size` — `:full` (default) or `:half`
      * Controls CPU allocation on the target cluster
      * `:full` → `--exclusive` with all node CPUs
      * `:half` → no `--exclusive`, half the node's CPUs
      * Auto-detected per cluster (Helma: 384/192, Fritz: 72/36, spr*: 104/52)
    * `:timeout_seconds` — per-problem limit (default: 60)
    * `:partition` — SLURM partition (default: "cpu")
    * `:max_parallel_jobs` — max concurrent tasks (default: 4)
    * `:wait_for_completion` — poll until done (default: true)
    * `:prepare_images` — auto-build missing SIF images (default: false)

      plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
               mode: :hpc,
               hpc_mode: :multi_node,
               node_size: :half
             )
      results = AtpBenchmarkRunner.run_benchmark(plan)
  """
  @spec bootstrap(
          HpcConnect.Session.t(),
          [Prover.t() | atom() | binary()],
          [AtpBenchmarkRunner.Problem.t() | binary()],
          keyword()
        ) :: Run.t()
  def bootstrap(session, provers, problems, opts) do
    mode = Keyword.get(opts, :mode, :hpc)
    # keep mode check for future validation
    _ = mode

    provers_norm = normalize_provers(provers)
    problems_norm = normalize_problems(problems)

    hpc_config =
      HPCConfig.resolve(session, Keyword.put(opts, :prover_count, length(provers_norm)))

    Run.new(
      title: Keyword.get(opts, :title, "HPC benchmark run"),
      cluster: hpc_config.cluster,
      partition: hpc_config.partition,
      remote_root: hpc_config.remote_root,
      walltime: hpc_config.walltime,
      max_parallel_jobs: hpc_config.max_parallel_jobs,
      problems: problems_norm,
      provers: provers_norm,
      problem_timeout_seconds: Keyword.get(opts, :timeout_seconds, 60),
      metadata: %{
        mode: :hpc,
        hpc_mode: hpc_config.hpc_mode,
        hpc: hpc_config,
        session_config: session_config(session)
      }
    )
  end

  @doc """
  Executes a benchmark plan created by `bootstrap/3` or `bootstrap/4`.

  Dispatches to the appropriate runner based on the plan's mode metadata.
  Prints timing information and returns the list of `Result` structs.
  """
  @spec run_benchmark(Run.t()) :: [Result.t()]
  def run_benchmark(%Run{} = plan) do
    mode = plan.metadata[:mode] || :local

    {t_ms, results} =
      :timer.tc(fn ->
        case mode do
          :local ->
            include_raw = Map.get(plan.metadata, :include_raw_output, true)
            auto_ensure = Map.get(plan.metadata, :auto_ensure_images, false)
            timeout_seconds = plan.problem_timeout_seconds

            LocalRunner.run_benchmark(plan.provers, plan.problems,
              timeout_seconds: timeout_seconds,
              include_raw_output: include_raw,
              auto_ensure_images: auto_ensure,
              execution_strategy: plan.metadata[:execution_strategy] || :sequential_containers
            )

          :hpc ->
            session = session_from_plan(plan)

            plan
            |> AtpBenchmarkRunner.HPC.Runner.run(session, wait_for_completion: true)
            |> Map.fetch!(:results)

          _ ->
            raise ArgumentError, "Unknown mode in plan: #{inspect(mode)}"
        end
      end)

    elapsed_s = t_ms / 1_000_000
    IO.puts("Benchmark completed in #{Float.round(elapsed_s, 2)}s")
    IO.puts("Total results: #{length(results)}")
    results
  end

  @doc """
  Prints a compact Markdown results table for the given results.

  Set `memory: true` to include a Memory (KB) column (used by the HPC notebook).

      AtpBenchmarkRunner.results_table(results)
      AtpBenchmarkRunner.results_table(results, memory: true)
  """
  @spec results_table([Result.t()], keyword()) :: :ok
  def results_table(results, opts \\ []) do
    memory? = Keyword.get(opts, :memory, false)

    if memory? do
      IO.puts("| # | Problem | Prover | SZS Status | Wall (ms) | Memory (KB) | Solved? |")
      IO.puts("|---|---------|--------|------------|-----------|-------------|---------|")
    else
      IO.puts("| # | Problem | Prover | SZS Status | Wall (ms) | Solved? |")
      IO.puts("|---|---------|--------|------------|-----------|---------|")
    end

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {r, i} ->
      solved = if Result.solved?(r), do: "✅", else: "❌"

      if memory? do
        IO.puts(
          "| #{i} | #{r.problem_id} | #{r.prover} | #{r.szs_status || "?"} | #{r.wall_time_ms || "?"} | #{r.memory_kb || "?"} | #{solved} |"
        )
      else
        IO.puts(
          "| #{i} | #{r.problem_id} | #{r.prover} | #{r.szs_status || "?"} | #{r.wall_time_ms || "?"} | #{solved} |"
        )
      end
    end)
  end

  @doc """
  Runs all selected provers against all selected problems locally (sequentially).
  """
  @spec local_benchmark(
          [Prover.t() | atom() | binary()],
          [AtpBenchmarkRunner.Problem.t() | binary()],
          keyword()
        ) :: [Result.t()]
  def local_benchmark(provers, problems, opts \\ []),
    do: LocalRunner.run_benchmark(provers, problems, opts)

  @doc """
  Runs a single prover against a single problem locally.
  """
  @spec local_run_single(
          Prover.t() | atom() | binary(),
          AtpBenchmarkRunner.Problem.t() | binary(),
          keyword()
        ) :: Result.t()
  def local_run_single(prover, problem, opts \\ []),
    do: LocalRunner.run_single(prover, problem, opts)

  @doc """
  Compares two stored runs and returns longitudinal new-solve/regression deltas.

  Each side may be:

    * a `Run` struct,
    * a list of `Result`/`local-DB record` maps,
    * a path to a saved `.results.json` artifact, or
    * a run id (loaded from the local DB).

  When no records exist for a side, an empty list is used.
  """
  @spec compare_runs(
          Run.t() | [Result.t() | map()] | binary(),
          Run.t() | [Result.t() | map()] | binary(),
          keyword()
        ) :: map()
  def compare_runs(left, right, opts \\ []) do
    Compare.diff(resolve_side(left, opts), resolve_side(right, opts), opts)
  end

  @doc """
  Renders a `compare_runs/3` diff as a Markdown summary.
  """
  @spec diff_markdown(map()) :: binary()
  def diff_markdown(diff), do: Compare.markdown(diff)

  defp resolve_side(%Run{} = _run, _opts), do: []
  defp resolve_side(results, _opts) when is_list(results), do: results

  defp resolve_side(path, opts) when is_binary(path) do
    cond do
      String.ends_with?(path, ".results.json") ->
        Store.load_results!(path)

      File.exists?(path) ->
        Store.load_results!(path)

      true ->
        Store.load_db_results!(path, opts)
    end
  end

  @doc """
  Saves a run manifest to the local recovery store.
  """
  @spec save_run!(Run.t(), keyword()) :: binary()
  def save_run!(%Run{} = run, opts \\ []), do: Store.save_run!(run, opts)

  @doc """
  Saves parsed results to the local store.
  """
  @spec save_results!(Run.t(), [Result.t() | map()], keyword()) :: binary()
  def save_results!(%Run{} = run, results, opts \\ []),
    do: Store.save_results!(run, results, opts)

  @doc """
  Saves a report with reproducibility metadata.
  """
  @spec save_report!(Run.t(), map(), keyword()) :: binary()
  def save_report!(%Run{} = run, report, opts \\ []),
    do: Store.save_report!(run, report, opts)

  @doc """
  Stores a run, result list, and report in the local lightweight DB.
  """
  @spec save_to_db!(Run.t(), [Result.t() | map()], map(), keyword()) :: map()
  def save_to_db!(%Run{} = run, results, report, opts \\ []),
    do: Store.save_to_db!(run, results, report, opts)

  @doc """
  Lists normalized run records from the local lightweight DB.
  """
  @spec list_db_runs(keyword()) :: [map()]
  def list_db_runs(opts \\ []), do: Store.list_db_runs(opts)

  @doc """
  Loads normalized result records from the local lightweight DB for one run.
  """
  @spec load_db_results!(binary(), keyword()) :: [map()]
  def load_db_results!(run_id, opts \\ []), do: Store.load_db_results!(run_id, opts)

  @doc """
  Loads a stored report record from the local lightweight DB.
  """
  @spec load_db_report(binary(), keyword()) :: map() | nil
  def load_db_report(run_id, opts \\ []), do: Store.load_db_report(run_id, opts)

  @doc """
  Opens the Livebook/Kino dashboard if available.
  """
  @spec livebook_dashboard(HpcConnect.Session.t() | nil, keyword()) :: map() | term()
  def livebook_dashboard(session \\ nil, opts \\ []),
    do: AtpBenchmarkRunner.GUI.Dashboard.overlay(session, opts)

  @doc """
  Opens the Livebook/Kino TPTP preparation panel if available.
  """
  @spec tptp_panel(keyword()) :: map() | term()
  def tptp_panel(opts \\ []), do: AtpBenchmarkRunner.GUI.TPTP.panel(opts)

  @doc """
  Opens a Livebook/Kino report panel if available.
  """
  @spec report_panel([Result.t() | map()] | map(), Run.t() | nil, keyword()) :: map() | term()
  def report_panel(results_or_report, run \\ nil, opts \\ []),
    do: AtpBenchmarkRunner.GUI.Report.panel(results_or_report, run, opts)

  @doc """
  Renders a longitudinal diff between two result lists as a Kino panel.
  """
  @spec diff_panel([Result.t() | map()], [Result.t() | map()], keyword()) :: map() | term()
  def diff_panel(left, right, opts \\ []),
    do: AtpBenchmarkRunner.GUI.Report.diff_panel(left, right, opts)

  @doc """
  Opens a Livebook/Kino monitor panel if available.
  """
  @spec monitor_panel(HpcConnect.Session.t() | nil, Run.t() | nil, keyword()) :: map() | term()
  def monitor_panel(session, run, opts \\ []),
    do: AtpBenchmarkRunner.GUI.Monitor.panel(session, run, opts)

  @doc """
  Returns a human-readable explanation of a single prover result,
  including the SZS status, wall time, and proof snippet when available.
  """
  @spec explain(Result.t()) :: binary()
  def explain(%Result{} = result), do: Result.explain(result)

  @doc """
  Returns a detailed human-readable explanation of a single prover result,
  including proof snippets when available.

  Accepts a single result or a list of results.

      AtpBenchmarkRunner.explain_full(result)
      AtpBenchmarkRunner.explain_full(results) |> IO.puts()
  """
  @spec explain_full(Result.t() | [Result.t()]) :: binary()
  def explain_full(%Result{} = result), do: Result.explain_full(result)
  def explain_full(results) when is_list(results), do: Result.explain_full(results)

  @doc """
  Finds and displays a proof for a specific prover/problem combination.
  Prints directly to stdout.

      AtpBenchmarkRunner.show_proof(results, :vampire, "SMT001+0")
  """
  @spec show_proof([Result.t()], atom() | binary(), binary()) :: :ok
  def show_proof(results, prover, problem_id),
    do: Result.show_proof(results, prover, problem_id)

  @doc """
  Renders Mermaid visualizations for a result, a list of results, or a report.

  Visual companion to `explain/1` and `explain_full/1`. Inside Livebook this
  returns `Kino.Mermaid` output(s); elsewhere it returns a fenced markdown
  string you can paste into a markdown cell.

      AtpBenchmarkRunner.visualize(result)
      AtpBenchmarkRunner.visualize(results)
      AtpBenchmarkRunner.visualize(report)

  A single result renders a prover → problem → status → timing flowchart; a
  list renders a status pie plus a wall-time chart (pushed as two Livebook
  outputs, returning `:ok`); a report renders a scoreboard. See
  `AtpBenchmarkRunner.Visualize` for the raw builders.
  """
  @spec visualize(Result.t() | [Result.t()] | map(), keyword()) :: term()
  def visualize(input, opts \\ [])

  def visualize(%Result{} = result, opts),
    do: Visualize.render(Visualize.result(result, opts))

  def visualize(results, opts) when is_list(results) do
    diagrams = [Visualize.status_pie(results, opts), Visualize.timeline(results, opts)]

    if Visualize.available?() do
      Enum.each(diagrams, fn diagram -> Kino.render(Visualize.render(diagram, opts)) end)
      :ok
    else
      Enum.map(diagrams, &Visualize.markdown/1)
    end
  end

  def visualize(%{totals: _} = report, opts),
    do: Visualize.render(Visualize.report(report, opts))

  @doc """
  Renders the proof dependency graph for a result, or for the first result in
  a list that carries a parseable proof block.

      AtpBenchmarkRunner.visualize_proof(result)
      AtpBenchmarkRunner.visualize_proof(results)

  See `AtpBenchmarkRunner.Visualize.proof/2`.
  """
  @spec visualize_proof(Result.t() | [Result.t()], keyword()) :: term()
  def visualize_proof(input, opts \\ [])

  def visualize_proof(%Result{} = result, opts),
    do: Visualize.render(Visualize.proof(result, opts))

  def visualize_proof(results, opts) when is_list(results) do
    result =
      Enum.find(results, &match?({:ok, _}, AtpBenchmarkRunner.Visualize.Proof.parse(&1))) ||
        List.first(results)

    case result do
      nil -> "No results to visualize."
      result -> Visualize.render(Visualize.proof(result, opts))
    end
  end

  @doc """
  Prints the interesting findings section from a report to stdout.

      report = AtpBenchmarkRunner.report(results)
      AtpBenchmarkRunner.print_interesting(report)
  """
  @spec print_interesting(map()) :: :ok
  def print_interesting(report), do: Report.print_interesting(report)

  @doc """
  Prints a complete aggregated report (per-prover, per-problem, interesting) to stdout.

      report = AtpBenchmarkRunner.report(results)
      AtpBenchmarkRunner.print_report(report)
  """
  @spec print_report(map()) :: :ok
  def print_report(report), do: Report.print(report)

  @doc """
  Prints the per-prover breakdown table from a report to stdout.

      AtpBenchmarkRunner.print_per_prover(report)
  """
  @spec print_per_prover(map()) :: :ok
  def print_per_prover(report), do: Report.print_per_prover(report)

  @doc """
  Prints the per-problem comparison table from a report to stdout.

      AtpBenchmarkRunner.print_per_problem(report)
  """
  @spec print_per_problem(map()) :: :ok
  def print_per_problem(report), do: Report.print_per_problem(report)

  @doc """
  Prints the report's full Markdown blob to stdout (falls back to `print_report/1`
  when the report carries no `:markdown`).

      AtpBenchmarkRunner.print_report_markdown(report)
  """
  @spec print_report_markdown(map()) :: :ok
  def print_report_markdown(report) do
    if markdown = report[:markdown] || report["markdown"] do
      IO.puts(markdown)
    else
      print_report(report)
    end

    :ok
  end

  @doc """
  Prints full explained results (with proof snippets) to stdout.

      AtpBenchmarkRunner.print_explain_full(results)
  """
  @spec print_explain_full(Result.t() | [Result.t()]) :: :ok
  def print_explain_full(input), do: IO.puts(explain_full(input))

  @doc """
  Prints a verbose (per-result) report to stdout. Accepts the same options as
  `verbose_report/2` (`:prover`, `:problem`, `:solved_only`, `:failed_only`).

      AtpBenchmarkRunner.print_verbose_report(results, prover: :vampire, solved_only: true)
  """
  @spec print_verbose_report([Result.t()], keyword()) :: :ok
  def print_verbose_report(results, opts \\ []) do
    results |> verbose_report(opts) |> Enum.each(&IO.puts/1)
    :ok
  end

  @doc """
  Prints a longitudinal `compare_runs/3` diff as Markdown to stdout.

      diff = AtpBenchmarkRunner.compare_runs(left, right)
      AtpBenchmarkRunner.print_diff(diff)
  """
  @spec print_diff(map()) :: :ok
  def print_diff(diff), do: IO.puts(diff_markdown(diff))

  @doc """
  Prints the raw prover output for a specific prover/problem from a result list.

      AtpBenchmarkRunner.print_raw_output(results, :vampire, "GRP001-0")
  """
  @spec print_raw_output([Result.t()], atom() | binary(), binary()) :: :ok
  def print_raw_output(results, prover, problem_id) do
    result = Enum.find(results, &(&1.prover == prover and &1.problem_id == problem_id))

    cond do
      is_nil(result) ->
        IO.puts("Result not found for #{prover} / #{problem_id}")

      result.raw_output ->
        IO.puts("Raw output for #{result.problem_id} / #{result.prover}:\n")
        IO.puts(result.raw_output)

      true ->
        IO.puts("No raw output stored (rerun with include_raw_output: true)")
    end

    :ok
  end

  @doc """
  Returns a verbose report for one or more results as a list of explain strings.
  Useful for debugging or inspecting what each prover actually proved and how.

  ## Options

    * `:prover` — filter to a specific prover atom (e.g. `:eprover`)
    * `:problem` — filter to a specific problem id
    * `:solved_only` — only include solved results (default: false)
    * `:failed_only` — only include failed results (default: false)
  """
  @spec verbose_report([Result.t()], keyword()) :: [binary()]
  def verbose_report(results, opts \\ []) do
    results
    |> filter_results(opts)
    |> Enum.map(&Result.explain/1)
  end

  defp filter_results(results, opts) do
    results
    |> maybe_filter_prover(Keyword.get(opts, :prover))
    |> maybe_filter_problem(Keyword.get(opts, :problem))
    |> maybe_filter_solved(Keyword.get(opts, :solved_only))
    |> maybe_filter_failed(Keyword.get(opts, :failed_only))
  end

  defp maybe_filter_prover(results, nil), do: results
  defp maybe_filter_prover(results, prover), do: Enum.filter(results, &(&1.prover == prover))

  defp maybe_filter_problem(results, nil), do: results
  defp maybe_filter_problem(results, pid), do: Enum.filter(results, &(&1.problem_id == pid))

  defp maybe_filter_solved(results, true), do: Enum.filter(results, &Result.solved?/1)
  defp maybe_filter_solved(results, _), do: results

  defp maybe_filter_failed(results, true), do: Enum.reject(results, &Result.solved?/1)
  defp maybe_filter_failed(results, _), do: results

  @doc """
  Builds a notification payload for a completed benchmark report.
  """
  @spec notification_payload(map() | [map()], Run.t() | nil, keyword()) :: map()
  def notification_payload(report_or_results, run \\ nil, opts \\ []),
    do: Notification.payload(report_or_results, run, opts)

  @doc """
  Sends a completed benchmark report to a configured webhook.
  """
  @spec send_webhook_notification(map() | [map()], Run.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_webhook_notification(report_or_results, run \\ nil, opts \\ []),
    do: Notification.send_webhook(report_or_results, run, opts)

  @doc """
  Writes an email-ready Markdown summary artifact for a benchmark report.
  """
  @spec write_email_summary!(map() | [map()], Run.t() | nil, keyword()) :: binary()
  def write_email_summary!(report_or_results, run \\ nil, opts \\ []),
    do: Notification.write_email_summary!(report_or_results, run, opts)

  defp session_from_plan(%Run{metadata: %{session_config: session_config}})
       when is_map(session_config) do
    cluster = Map.get(session_config, :cluster) || Map.get(session_config, "cluster")

    opts =
      session_config
      |> Map.drop([:cluster, "cluster"])
      |> Enum.map(fn {key, value} -> {normalize_session_config_key(key), value} end)

    HpcConnect.Session.new(cluster, opts)
  end

  defp session_from_plan(%Run{metadata: %{session: %HpcConnect.Session{} = session}}), do: session

  defp session_from_plan(%Run{}) do
    raise ArgumentError,
          "HPC run plan is missing a serializable session_config. Rebuild the plan with AtpBenchmarkRunner.bootstrap/4."
  end

  defp session_config(%HpcConnect.Session{} = session) do
    %{
      cluster: session.cluster.name,
      username: session.username,
      ssh_alias: session.ssh_alias,
      uploaded_key_path: session.uploaded_key_path,
      identity_file: session.identity_file,
      ssh_config_file: session.ssh_config_file,
      known_hosts_file: session.known_hosts_file,
      credential_dir: session.credential_dir,
      proxy_jump: session.proxy_jump,
      work_dir: session.work_dir,
      vault_dir: session.vault_dir,
      port_range: Tuple.to_list(session.port_range),
      env: session.env
    }
  end

  defp normalize_session_config_key("port_range"), do: :port_range
  defp normalize_session_config_key(:port_range), do: :port_range
  defp normalize_session_config_key(key) when is_binary(key), do: String.to_existing_atom(key)
  defp normalize_session_config_key(key) when is_atom(key), do: key

  # --- Normalization helpers ---

  defp normalize_provers(provers) when is_list(provers) do
    Enum.map(provers, &normalize_prover/1)
  end

  defp normalize_prover(%Prover{} = prover), do: prover
  defp normalize_prover(name) when is_atom(name) or is_binary(name), do: Prover.builtin!(name)

  defp normalize_problems(problems) when is_list(problems) do
    Enum.map(problems, &normalize_problem/1)
  end

  defp normalize_problem(%Problem{} = problem), do: problem
  defp normalize_problem(path) when is_binary(path), do: Problem.from_path(path)
end
