defmodule AtpBenchmarkRunnerTest do
  use ExUnit.Case

  alias AtpBenchmarkRunner.{Config, Problem, Prover, Result, Run, Store, TPTP}
  alias AtpBenchmarkRunner.HPC.{ImageSmokeTest, Images, JobScript, TPTPSync}

  test "parses TPTP header metadata" do
    content = """
    % File     : SET001^0 : TPTP v9.2.1
    % Status   : Theorem
    % Rating   : 0.00 v8.2.0
    % Syntax   : THF
    % SPC      : THF_THM_NEQ
    thf(foo,conjecture,$true).
    """

    parsed = Problem.parse_tptp_header(content)

    assert parsed.expected_status == "Theorem"
    assert parsed.rating == 0.0
    assert parsed.logic == "THF"
    assert parsed.metadata.file == "SET001^0 : TPTP v9.2.1"
    assert parsed.metadata.spc == "THF_THM_NEQ"
  end

  test "uses .env-backed TPTP directory configuration" do
    tmp = Path.join(System.tmp_dir!(), "atp_tptp_env_#{System.unique_integer([:positive])}")
    env_file = Path.join(tmp, ".env")
    tptp_dir = Path.join(tmp, "tptp")
    File.mkdir_p!(tmp)
    File.write!(env_file, "ATP_BENCHMARK_RUNNER_TPTP_DIR=#{tptp_dir}\n")

    assert Config.tptp_dir(env_file: env_file) == Path.expand(tptp_dir)
  end

  test "describes the official TPTP archive" do
    [archive] = AtpBenchmarkRunner.tptp_archives()

    assert archive.version == "9.2.1"
    assert archive.archive_name == "TPTP-v9.2.1.tgz"
    assert archive.url == "https://tptp.org/TPTP/TPTP-v9.2.1.tgz"
  end

  test "installs bundled examples and loads filtered problem sets" do
    tmp = Path.join(System.tmp_dir!(), "atp_tptp_examples_#{System.unique_integer([:positive])}")

    installed = AtpBenchmarkRunner.install_tptp_examples!(root_dir: tmp)

    assert length(installed) == 3

    problems =
      AtpBenchmarkRunner.load_tptp_problems(
        root_dir: tmp,
        forms: ["FOF"],
        status: "Theorem",
        rating_max: "0.25",
        include_axioms?: true,
        limit: 10
      )

    assert [%Problem{name: "PUZ001+0", logic: "FOF", domain: "PUZ"} = problem] = problems
    assert problem.rating == 0.0
  end

  test "selects TPTP files from GUI form data without downloading by default" do
    tmp = Path.join(System.tmp_dir!(), "atp_tptp_gui_#{System.unique_integer([:positive])}")
    TPTP.install_examples!(root_dir: tmp)

    selection =
      AtpBenchmarkRunner.GUI.TPTP.selection_from_form(%{
        "tptp_root_dir" => tmp,
        "install_examples" => false,
        "download_full_archive" => false,
        "forms" => ["CNF"],
        "limit" => 5
      })

    assert selection.summary.count == 1
    assert [%Problem{name: "GRP001-0"}] = selection.problems
  end

  test "built-in provers render shell-safe command templates" do
    prover = Prover.builtin!(:vampire)

    command =
      Prover.render_command(prover, "/remote/TPTP/SET001^1.p",
        timeout_seconds: 60,
        sif_path: "/apps/vampire.sif"
      )

    assert command =~ "apptainer exec '/apps/vampire.sif' vampire"
    assert command =~ "--time_limit 60"
    assert command =~ "'/remote/TPTP/SET001^1.p'"
  end

  test "provider registry includes famous provers and aliases" do
    names = AtpBenchmarkRunner.built_in_provers() |> Enum.map(& &1.name)

    assert :vampire in names
    assert :eprover in names
    assert :cvc5 in names
    assert :zipperposition in names
    assert :leo3 in names
    assert :leo2 in names
    assert Prover.builtin!(:zipperpin).name == :zipperposition
  end

  test "image plan points at bundled Apptainer definitions" do
    [entry] = Images.plan([Prover.builtin!(:vampire)])

    assert entry.prover == :vampire
    assert entry.local_def_path =~ "priv"
    assert entry.local_def_path =~ "vampire"
    assert entry.local_def_path =~ "apptainer.def"
  end

  test "image build plan uses hpc_connect remote def and sif conventions" do
    session =
      HpcConnect.new_session(:fritz,
        username: "tester",
        work_dir: "/home/hpc/test/tester/.cache/hpc_connect",
        vault_dir: "/home/vault/test/tester"
      )

    plan = AtpBenchmarkRunner.image_build_plan(session, [Prover.builtin!(:vampire)])

    assert plan.strategy.owner == :atp_benchmark_runner
    assert plan.strategy.build_script_owner == :hpc_connect
    assert plan.install_hpc_connect_scripts? == true

    assert [entry] = plan.entries
    assert entry.def_name == "vampire"
    assert entry.local_def_exists? == true
    assert entry.remote_def_path =~ "/singularity_def_files/vampire.def"
    assert entry.remote_sif_path =~ "/singularity_images/vampire.sif"
  end

  test "TPTP sync plan maps local files to remote HPC storage" do
    tmp = Path.join(System.tmp_dir!(), "atp_tptp_sync_#{System.unique_integer([:positive])}")
    [path | _] = TPTP.install_examples!(root_dir: tmp)
    problem = Problem.from_tptp_file(path)

    session = test_session()
    plan = TPTPSync.plan(session, [problem], remote_tptp_dir: "/vault/atp/tptp")

    assert plan.local_files == 1
    assert [%{upload?: true, remote_path: remote_path}] = plan.entries
    assert remote_path =~ "/vault/atp/tptp/"
    assert remote_path =~ Path.basename(path)
  end

  test "image smoke plan chooses bundled examples and remote SIF paths" do
    session = test_session()
    [entry] = ImageSmokeTest.plan(session, [Prover.builtin!(:vampire)]).entries

    assert entry.prover == :vampire
    assert entry.sif_path =~ "/singularity_images/vampire.sif"
    assert entry.remote_problem_path =~ "/atp_benchmark_runner/smoke/"
    assert entry.command =~ "apptainer exec"
  end

  test "can generate Kubernetes job manifest for future container backend" do
    manifest = AtpBenchmarkRunner.kubernetes_job(:cvc5, "/problems/demo.p", timeout_seconds: 15)

    assert manifest.kind == "Job"

    assert [%{image: "aise/atp-cvc5:latest", args: [arg]}] =
             manifest.spec.template.spec.containers

    assert arg =~ "timeout --preserve-status 15s cvc5"
    assert arg =~ "'/problems/demo.p'"
  end

  test "builds SLURM job-array script for a run" do
    run =
      Run.new(
        id: "run_test",
        partition: "singlenode",
        problems: ["/remote/tptp/A.p", "/remote/tptp/B.ax"],
        provers: [:vampire],
        problem_timeout_seconds: 30,
        max_parallel_jobs: 2
      )

    script = JobScript.build(run, Prover.builtin!(:vampire), "/work/atp")

    assert script =~ "#SBATCH --array=1-2%2"
    assert script =~ "#SBATCH --partition=singlenode"
    assert script =~ "timeout --preserve-status"
    assert script =~ "SZS status Timeout"
    assert script =~ "PROBLEM_ID=\"${PROBLEM_BASENAME%.*}\""
    assert script =~ "RESOURCE_FILE=\"$RESULT_DIR/${PROBLEM_ID}.resources.txt\""
    assert script =~ "memory_kb"
  end

  test "aggregates SZS results into comparison report" do
    run =
      Run.new(
        problems: [
          Problem.new(id: "easy", name: "easy", rating: 0.0),
          Problem.new(id: "hard", name: "hard", rating: 1.0)
        ],
        provers: [:tableaux, :vampire]
      )

    results = [
      Result.new(problem_id: "easy", prover: :tableaux, szs_status: "Timeout"),
      Result.new(problem_id: "easy", prover: :vampire, szs_status: "Theorem"),
      Result.new(problem_id: "hard", prover: :tableaux, szs_status: "Theorem")
    ]

    report = AtpBenchmarkRunner.report(results, run)

    assert report.run_id == run.id
    assert report.totals.solved_results == 2
    assert Enum.any?(report.result_rows, &(&1.memory_kb == nil and &1.problem_id == "easy"))
    assert [%{prover: :tableaux, buckets: buckets} | _] = report.by_rating_bucket
    assert Enum.any?(buckets, &(&1.bucket == "0.0-0.1"))
    assert [%{problem_id: "easy"}] = report.interesting.easy_failed_by_ours
    assert [%{problem_id: "hard"}] = report.interesting.hard_solved_by_ours
  end

  test "result records carry run and collection metadata" do
    result =
      Result.from_output(:vampire, "SET001^0", "% SZS status Theorem for SET001^0",
        run_id: "run_meta",
        collected_at: "2026-06-01T12:00:00Z",
        wall_time_ms: 1234,
        memory_kb: 4096
      )

    persisted = Result.to_map(result)

    assert result.run_id == "run_meta"
    assert result.collected_at == "2026-06-01T12:00:00Z"
    assert result.szs_status == "Theorem"
    assert Result.from_map(persisted).memory_kb == 4096
  end

  test "parses sacct output for completed job monitoring" do
    rows =
      AtpBenchmarkRunner.Monitor.parse_sacct("""
      123|COMPLETED|0:0|00:01:00|128K
      124.batch|FAILED|1:0|00:00:02|64K
      """)

    assert [%{job_id: "123", state: "COMPLETED"}, %{job_id: "124.batch", state: "FAILED"}] = rows
  end

  test "renders monitor snapshots for Livebook and local fallback" do
    snapshot = %{
      run_id: "run_monitor",
      status: :running,
      polled_at: "2026-06-01T12:00:00Z",
      progress: [
        %{
          prover: :vampire,
          total: 10,
          completed: 6,
          pending: 4,
          completion_rate: 0.6,
          output_files: 6,
          metadata_files: 6,
          result_dir: "/remote/results/vampire"
        }
      ],
      stuck_jobs: [%{job_id: "123", state: "RUNNING"}]
    }

    markdown = AtpBenchmarkRunner.GUI.Monitor.progress_markdown(snapshot)
    fallback = AtpBenchmarkRunner.monitor_panel(nil, nil, snapshot: snapshot)

    assert markdown =~ "`vampire`"
    assert markdown =~ "6/10 completed"

    assert [%{prover: :vampire, completed: 6}] =
             AtpBenchmarkRunner.GUI.Monitor.progress_rows(snapshot)

    assert fallback.snapshot == snapshot
  end

  test "persists and reloads run manifests" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "atp_benchmark_runner_test_#{System.unique_integer([:positive])}"
      )

    run = Run.new(id: "persisted", problems: ["/remote/problem.p"], provers: [:cvc5])

    path = Store.save_run!(run, dir: tmp)
    loaded = Store.load_run!(path)

    assert loaded.id == "persisted"
    assert [%Problem{name: "problem"}] = loaded.problems
    assert [%Prover{name: :cvc5}] = loaded.provers

    results_path =
      Store.save_results!(
        run,
        [Result.new(problem_id: "problem", prover: :cvc5, szs_status: "Theorem")],
        dir: tmp,
        git_commit: "abc123"
      )

    assert [%Result{problem_id: "problem", prover: :cvc5}] = Store.load_results!(results_path)
  end

  test "persists normalized run results into the local lightweight DB" do
    tmp = Path.join(System.tmp_dir!(), "atp_local_db_#{System.unique_integer([:positive])}")

    run =
      Run.new(
        id: "db_run",
        problems: [Problem.new(id: "p1", name: "p1", rating: 0.0)],
        provers: [:tableaux, :vampire]
      )

    results = [
      Result.new(
        run_id: run.id,
        problem_id: "p1",
        problem_name: "p1",
        prover: :tableaux,
        szs_status: "Theorem",
        wall_time_ms: 42,
        memory_kb: 512
      )
    ]

    report = AtpBenchmarkRunner.report(results, run)
    db = AtpBenchmarkRunner.save_to_db!(run, results, report, dir: tmp)

    assert db.db_path =~ "atp_benchmark_runner.dets"
    assert [%{id: "db_run", problem_count: 1}] = AtpBenchmarkRunner.list_db_runs(dir: tmp)

    assert [record] = AtpBenchmarkRunner.load_db_results!("db_run", dir: tmp)
    assert record.run_id == "db_run"
    assert record.prover == :tableaux
    assert record.solved == true
    assert record.memory_kb == 512

    assert %{run_id: "db_run"} = AtpBenchmarkRunner.load_db_report("db_run", dir: tmp)
  end

  test "scheduler exposes optional Oban configuration" do
    config = AtpBenchmarkRunner.Scheduler.oban_config(cron: "0 21 * * *", queue: :nightly)

    assert Keyword.fetch!(config, :queues) == [nightly: 1]
    assert AtpBenchmarkRunner.Scheduler.available?() in [true, false]
  end

  test "scheduler can dispatch a host runner MFA" do
    job = %{
      args: %{
        "runner_mfa" => %{
          "module" => "AtpBenchmarkRunnerTest.Runner",
          "function" => "perform",
          "args" => [%{"run_id" => "nightly"}]
        }
      }
    }

    assert AtpBenchmarkRunner.Scheduler.perform(job) == {:ok, %{"run_id" => "nightly"}}
  end

  test "writes remote files using POSIX directories on Windows hosts" do
    command = JobScript.write_file_command("/remote/atp/scripts/vampire.sbatch", "echo ok")

    assert command =~ "mkdir -p '/remote/atp/scripts'"
    refute command =~ "\\"
  end

  test "compare_runs surfaces new solves, regressions and per-prover deltas" do
    left = [
      Result.new(problem_id: "p1", prover: :tableaux, szs_status: "Theorem"),
      Result.new(problem_id: "p2", prover: :tableaux, szs_status: "Theorem"),
      Result.new(problem_id: "p3", prover: :tableaux, szs_status: "Timeout")
    ]

    right = [
      Result.new(problem_id: "p1", prover: :tableaux, szs_status: "Theorem"),
      Result.new(problem_id: "p2", prover: :tableaux, szs_status: "Timeout"),
      Result.new(problem_id: "p3", prover: :tableaux, szs_status: "Theorem"),
      Result.new(problem_id: "p4", prover: :tableaux, szs_status: "Theorem")
    ]

    diff = AtpBenchmarkRunner.compare_runs(left, right, our_prover: :tableaux)

    new_solve_ids = diff.new_solves |> Enum.map(& &1.problem_id) |> Enum.sort()
    regression_ids = diff.regressions |> Enum.map(& &1.problem_id) |> Enum.sort()
    only_right_ids = diff.only_right |> Enum.map(& &1.problem_id) |> Enum.sort()

    assert new_solve_ids == ["p3", "p4"]
    assert regression_ids == ["p2"]
    assert only_right_ids == ["p4"]
    assert [%{prover: :tableaux, left_solved: 2, right_solved: 3}] = diff.per_prover_solve_deltas
    assert diff.left_run_id == nil
    assert diff.right_run_id == nil
  end

  test "compare_runs accepts DB-style maps with string keys" do
    left = [
      %{
        "run_id" => "db_left",
        "problem_id" => "p1",
        "prover" => :tableaux,
        "szs_status" => "Theorem",
        "solved" => true
      }
    ]

    right = [
      %{
        "run_id" => "db_right",
        "problem_id" => "p1",
        "prover" => :tableaux,
        "szs_status" => "Timeout",
        "solved" => false
      },
      %{
        "run_id" => "db_right",
        "problem_id" => "p2",
        "prover" => :tableaux,
        "szs_status" => "Theorem",
        "solved" => true
      }
    ]

    diff = AtpBenchmarkRunner.compare_runs(left, right)

    assert [%{problem_id: "p1"}] = diff.regressions
    assert [%{problem_id: "p2"}] = diff.new_solves
    assert diff.left_run_id == "db_left"
    assert diff.right_run_id == "db_right"
  end

  test "diff_markdown produces a summary that includes new solves and regressions" do
    left = [
      Result.new(problem_id: "p1", prover: :tableaux, szs_status: "Theorem")
    ]

    right = [
      Result.new(problem_id: "p1", prover: :tableaux, szs_status: "Timeout"),
      Result.new(problem_id: "p2", prover: :tableaux, szs_status: "Theorem")
    ]

    diff = AtpBenchmarkRunner.compare_runs(left, right)
    markdown = AtpBenchmarkRunner.diff_markdown(diff)

    assert markdown =~ "ATP benchmark run diff"
    assert markdown =~ "New solves: **1**"
    assert markdown =~ "Regressions: **1**"
  end

  test "Prover.builtin/1 returns nil for unknown names without creating atoms" do
    refute Prover.builtin("nonexistent_prover_xyz")
    assert %Prover{name: :vampire} = Prover.builtin("vampire")
  end

  test "Prover.normalize/1 raises for unknown prover names instead of creating atoms" do
    assert_raise ArgumentError, fn -> Prover.normalize("nonexistent_prover_xyz") end
  end

  test "LocalDb reads from the requested file even if another DETS file is already open" do
    tmp = Path.join(System.tmp_dir!(), "atp_local_db_paths_#{System.unique_integer([:positive])}")

    other =
      Path.join(System.tmp_dir!(), "atp_local_db_other_#{System.unique_integer([:positive])}")

    run_a =
      Run.new(id: "alpha", problems: [Problem.new(id: "p1", name: "p1")], provers: [:tableaux])

    run_b =
      Run.new(id: "beta", problems: [Problem.new(id: "p2", name: "p2")], provers: [:tableaux])

    AtpBenchmarkRunner.save_to_db!(
      run_a,
      [Result.new(problem_id: "p1", prover: :tableaux, szs_status: "Theorem")],
      %{},
      dir: tmp
    )

    AtpBenchmarkRunner.save_to_db!(
      run_b,
      [Result.new(problem_id: "p2", prover: :tableaux, szs_status: "Theorem")],
      %{},
      dir: other
    )

    assert [%{id: "alpha", problem_count: 1}] = AtpBenchmarkRunner.list_db_runs(dir: tmp)
    assert [%{id: "beta", problem_count: 1}] = AtpBenchmarkRunner.list_db_runs(dir: other)

    assert [record] = AtpBenchmarkRunner.load_db_results!("alpha", dir: tmp)
    assert record.problem_id == "p1"
  end

  test "Scheduler.runner_args/1 returns a documented nightly job argument map" do
    args =
      AtpBenchmarkRunner.Scheduler.runner_args(
        module: "MyApp.AtpNightly",
        function: "run",
        args: [%{"cluster" => "fritz"}],
        cluster: "fritz",
        provers: ["vampire"]
      )

    assert args["cluster"] == "fritz"
    assert args["provers"] == ["vampire"]
    assert args["runner_mfa"]["module"] == "MyApp.AtpNightly"
    assert args["runner_mfa"]["function"] == "run"
    assert args["runner_mfa"]["args"] == [%{"cluster" => "fritz"}]
  end

  test "ignores unknown persisted keys without creating dynamic top-level atoms" do
    new_run =
      Run.new(%{
        "id" => "from_string_map",
        "status" => "submitted",
        "problems" => ["/remote/string_map_problem.p"],
        "provers" => ["vampire"]
      })

    run =
      Run.from_map(%{
        "id" => "safe_keys",
        "problems" => [%{"id" => "p1", "name" => "p1", "unexpected_problem_key" => "ignored"}],
        "provers" => [Map.put(Prover.to_map(Prover.builtin!(:vampire)), "unexpected", "ignored")],
        "unexpected_run_key" => "ignored"
      })

    result =
      Result.from_map(%{
        "problem_id" => "p1",
        "prover" => "vampire",
        "szs_status" => "Theorem",
        "unexpected_result_key" => "ignored"
      })

    assert new_run.id == "from_string_map"
    assert new_run.status == :submitted
    assert [%Problem{name: "string_map_problem"}] = new_run.problems
    assert [%Prover{name: :vampire}] = new_run.provers
    assert run.id == "safe_keys"
    assert [%Problem{id: "p1"}] = run.problems
    assert [%Prover{name: :vampire}] = run.provers
    assert %Result{problem_id: "p1", prover: :vampire} = result
  end

  test "builds notification payloads and email summary artifacts" do
    tmp = Path.join(System.tmp_dir!(), "atp_notification_#{System.unique_integer([:positive])}")
    run = Run.new(id: "notify_run", problems: [Problem.new(id: "p1")], provers: [:vampire])

    report =
      AtpBenchmarkRunner.report(
        [Result.new(problem_id: "p1", prover: :vampire, szs_status: "Theorem")],
        run
      )

    payload = AtpBenchmarkRunner.notification_payload(report, run)

    path =
      AtpBenchmarkRunner.write_email_summary!(report, run,
        dir: tmp,
        recipients: ["team@example.org"]
      )

    assert payload.event == "atp_benchmark.completed"
    assert payload.run_id == "notify_run"
    assert File.read!(path) =~ "team@example.org"

    assert {:error, :missing_webhook_url} =
             AtpBenchmarkRunner.send_webhook_notification(report, run)
  end

  test "builds notification artifacts without a run struct" do
    tmp =
      Path.join(System.tmp_dir!(), "atp_notification_nil_#{System.unique_integer([:positive])}")

    report = %{run_id: "report_only", totals: %{total_results: 0}, markdown: "## Done"}

    json_report = %{
      "run_id" => "json_report",
      "totals" => %{"total_results" => 1},
      "markdown" => "## JSON"
    }

    payload = AtpBenchmarkRunner.notification_payload(report, nil)
    path = AtpBenchmarkRunner.write_email_summary!(report, nil, dir: tmp)
    json_payload = AtpBenchmarkRunner.notification_payload(json_report, nil)

    assert payload.run_id == "report_only"
    assert json_payload.run_id == "json_report"
    assert json_payload.markdown == "## JSON"
    assert File.read!(path) =~ "## Done"
  end

  defp test_session do
    HpcConnect.new_session(:fritz,
      username: "tester",
      work_dir: "/home/hpc/test/tester/.cache/hpc_connect",
      vault_dir: "/home/vault/test/tester"
    )
  end
end

defmodule AtpBenchmarkRunnerTest.Runner do
  def perform(args), do: {:ok, args}
end
