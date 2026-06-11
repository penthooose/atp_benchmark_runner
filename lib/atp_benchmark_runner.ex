defmodule AtpBenchmarkRunner do
  @moduledoc """
  High-level API for ATP benchmark runs.

  The library is designed to be imported into Livebook, local scripts, or IEx.
  Cluster interaction is delegated to the local `hpc_connect` project so this
  package stays focused on benchmark domain logic and reporting.
  """

  alias AtpBenchmarkRunner.{
    Compare,
    Notification,
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
end
