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

  @doc """
  Returns the configured store/artifact directory for run manifests, results, and reports.

  Configure via `ATP_BENCHMARK_RUNNER_STORE_DIR` env var (preferred),
  `ATP_BENCHMARK_RUNNER_CACHE_DIR` env var (fallback), or the `:dir` option.

  See `AtpBenchmarkRunner.Config.store_dir/1` for full resolution order.
  """
  @spec store_dir(keyword()) :: binary()
  def store_dir(opts \\ []), do: Config.store_dir(opts)

  @doc """
  Returns the configured TPTP root directory for local problem files.

  Configure via `ATP_BENCHMARK_RUNNER_TPTP_DIR` env var, `TPTP_DIR` env var,
  `:tptp_dir` application env, or the `:tptp_dir` / `:root_dir` option.

  See `AtpBenchmarkRunner.Config.tptp_dir/1` for full resolution order.
  """
  @spec tptp_dir(keyword()) :: binary()
  def tptp_dir(opts \\ []), do: Config.tptp_dir(opts)

  @doc """
  Converts a TPTP problem file to SMT-LIB format string.

  Useful when running provers (like CVC5) that don't natively parse TPTP.

  ## Examples

      smt = AtpBenchmarkRunner.convert_tptp_to_smt!("path/to/problem.p")
      File.write!("problem.smt2", smt)

  See `AtpBenchmarkRunner.TPTPToSMT` for full documentation.
  """
  @spec convert_tptp_to_smt!(binary()) :: binary()
  def convert_tptp_to_smt!(path) when is_binary(path),
    do: AtpBenchmarkRunner.TPTPToSMT.convert_file!(path)

  @doc """
  Converts a TPTP problem file to SMT-LIB and writes it to the configured temp directory.

  Returns the path to the written `.smt2` file.

  The temp directory is resolved via `Config.smt_tmp_dir/1` and can be
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
  """
  @spec build_prover_images!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def build_prover_images!(session, provers, opts \\ []),
    do: Images.build_all!(session, provers, opts)

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
  Loads local TPTP files into benchmark problem structs.
  """
  @spec load_tptp_problems(keyword()) :: [AtpBenchmarkRunner.Problem.t()]
  def load_tptp_problems(opts \\ []), do: TPTP.load_problem_set(opts)

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
  Creates a benchmark plan (Run struct) from provers, problems, and execution options.

  This is the main entry point for configuring a benchmark without running it.
  Use `run_benchmark/1` to execute the plan.

  ## Modes

  ### :local (default)
  Runs provers sequentially, with each prover running all problems before
  switching to the next prover. This reduces container loading times since
  each container is started once and reused for all problems.

      plan = AtpBenchmarkRunner.bootstrap(provers, problems, mode: :local)
      results = AtpBenchmarkRunner.run_benchmark(plan)

  ### :hpc
  Runs provers in parallel on HPC resources, with one prover per compute node.
  Requires `hpc_connect` session and cluster configuration.

      plan = AtpBenchmarkRunner.bootstrap(session, provers, problems, mode: :hpc)
      results = AtpBenchmarkRunner.run_benchmark(plan)

  ## HPC Modes (when mode: :hpc)

    * `:single_node` - All provers run on a single compute node (default)
    * `:multi_node` - Each prover runs on a separate compute node

  ## Options

    * `:mode` — Execution mode: `:local` or `:hpc` (default: `:local`)
    * `:hpc_mode` — HPC execution mode: `:single_node` or `:multi_node` (default: `:single_node`)
    * `:timeout_seconds` — Per-problem wall time limit (default: 60)
    * `:include_raw_output` — Include full stdout in results (default: false)
    * `:auto_ensure_images` — Automatically pull/build missing Docker images (default: false)
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

      plan = AtpBenchmarkRunner.bootstrap(session, provers, problems,
               mode: :hpc,
               hpc_mode: :multi_node
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

    hpc_mode = Keyword.get(opts, :hpc_mode, :single_node)
    provers_norm = normalize_provers(provers)
    problems_norm = normalize_problems(problems)

    Run.new(
      title: Keyword.get(opts, :title, "HPC benchmark run"),
      problems: problems_norm,
      provers: provers_norm,
      problem_timeout_seconds: Keyword.get(opts, :timeout_seconds, 60),
      metadata: %{
        mode: :hpc,
        hpc_mode: hpc_mode,
        session: session
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
            session = plan.metadata[:session]
            hpc_mode = plan.metadata[:hpc_mode] || :single_node

            AtpBenchmarkRunner.HPC.Runner.bootstrap(session, plan.provers, plan.problems,
              hpc_mode: hpc_mode,
              timeout_seconds: plan.problem_timeout_seconds
            )

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

      AtpBenchmarkRunner.results_table(results)
  """
  @spec results_table([Result.t()]) :: :ok
  def results_table(results) do
    IO.puts("| # | Problem | Prover | SZS Status | Wall Time (ms) | Solved? |")
    IO.puts("|---|---------|--------|------------|-----------------|---------|")

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {r, i} ->
      solved = if Result.solved?(r), do: "✅", else: "❌"

      IO.puts(
        "| #{i} | #{r.problem_id} | #{r.prover} | #{r.szs_status || "?"} | #{r.wall_time_ms || "?"} | #{solved} |"
      )
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
