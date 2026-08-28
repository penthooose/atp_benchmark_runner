# Reproduces `examples/benchmark_hpc.livemd` §1→§7 under `mix run` and collects
# diagnostics for the Livebook-only failure:
#
#     "Runtime terminated unexpectedly - no connection"
#
# Hypothesis under test: the HPC sync (which gained shot_tx recently) uploads
# corrupted/malformed files, or makes too many/too-large SSH calls, and that is
# what kills the Livebook embedded runtime. This script replicates every step
# and verifies the uploaded files by checksum so we can tell the difference
# between "bad bytes on the cluster" vs "SSH/steady/runtime issue".
#
# Run (default — sync + upload checksum-verify + submit smoke, quick):
#     mix run testing/reproduce_hpc_livebook.exs
#
# Run (exact §7 replica — full run_benchmark incl. wait + collect, LONG):
#     $env:DIAG_FULL="true"; mix run testing/reproduce_hpc_livebook.exs

defmodule DiagRepro do
  @moduledoc false

  def md5_hex(binary), do: :crypto.hash(:md5, binary) |> Base.encode16(case: :lower)

  def step(label, fun) do
    t0 = System.monotonic_time(:millisecond)

    try do
      value = fun.()
      IO.puts("  ✓ #{label}  (#{ms(t0)} ms)")
      value
    rescue
      e ->
        IO.puts("  ✗ #{label} raised after #{ms(t0)} ms")
        IO.puts(Exception.format(:error, e, __STACKTRACE__))
        {:error, label, e}
    catch
      kind, reason ->
        IO.puts("  ✗ #{label} THREW #{inspect(kind)} #{inspect(reason)} after #{ms(t0)} ms")
        {:error, label, {kind, reason}}
    end
  end

  def ms(t0), do: System.monotonic_time(:millisecond) - t0

  def steady_state(session) do
    enabled = HpcConnect.SteadyConnection.enabled?(session)
    connected = HpcConnect.SteadyConnection.connected?(session)
    key = HpcConnect.SteadyConnection.session_key(session)
    server = HpcConnect.SteadyConnection.lookup_server(key)
    "steady_enabled=#{enabled} connected=#{connected} server=#{inspect(server)} key=#{key}"
  end

  # Build the exact upload set the sync would send, from the problems the
  # sync returned (which carry remote paths + local originals).
  def upload_set(remote_problems) do
    Enum.flat_map(remote_problems, fn p ->
      local = p.metadata[:local_path] || p.metadata["local_path"]
      remote = p.path

      candidates = [
        {local, remote},
        {conversion(local, ".smt2"), conversion(remote, ".smt2")},
        {conversion(local, "_thf.p"), conversion(remote, "_thf.p")}
      ]

      Enum.filter(candidates, fn {l, _r} -> is_binary(l) and File.exists?(l) end)
    end)
  end

  def conversion(path, suffix) when is_binary(path) do
    path
    |> String.replace_suffix(".p", suffix)
    |> String.replace_suffix(".tptp", suffix)
  end

  def conversion(_, _), do: nil

  # One batched SSH call: md5 of every file under the remote tptp root.
  def remote_md5_map(session, root) do
    cmd =
      "cd #{AtpBenchmarkRunner.HPC.Shell.quote(root)} && " <>
        "find . -type f \\( -name '*.p' -o -name '*.smt2' -o -name '*.ax' \\) " <>
        "-exec md5sum {} + 2>/dev/null || echo __MD5_FAILED__"

    out = HpcConnect.connect!(session, cmd)

    if String.contains?(out, "__MD5_FAILED__") do
      IO.puts("    ⚠ md5sum not available remotely — falling back to cksum")
      fallback_cksum(session, root)
    else
      out
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, ~r{\s+}, parts: 2) do
          [md5, path] -> {Path.basename(path), md5}
          _ -> {"", ""}
        end
      end)
    end
  end

  defp fallback_cksum(session, root) do
    cmd =
      "cd #{AtpBenchmarkRunner.HPC.Shell.quote(root)} && " <>
        "find . -type f \\( -name '*.p' -o -name '*.smt2' -o -name '*.ax' \\) " <>
        "-exec cksum {} + 2>/dev/null"

    out = HpcConnect.connect!(session, cmd)

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, ~r{\s+}, parts: 3) do
        [crc, size, path] -> {Path.basename(path), "#{crc} #{size}"}
        _ -> {"", ""}
      end
    end)
  end

  def verify_uploads(session, remote_problems, root) do
    set = upload_set(remote_problems)

    if set == [] do
      IO.puts("    (no uploads to verify)")
      []
    else
      remote = remote_md5_map(session, root)

      Enum.map(set, fn {local, remote_path} ->
        name = Path.basename(remote_path)
        # Uploads are LF-normalized (CRLF is stripped), so normalize the local
        # side the same way before comparing — a raw md5 of a Windows file with
        # CRLF endings would otherwise report a false mismatch.
        local_md5 = local |> File.read!() |> String.replace("\r\n", "\n") |> md5_hex()

        case Map.fetch(remote, name) do
          {:ok, ^local_md5} ->
            {:ok, name}

          {:ok, other} ->
            {:mismatch, name, local_md5, other, byte_size(File.read!(local))}

          :error ->
            {:missing, name}
        end
      end)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# §0 runtime / env header
# ─────────────────────────────────────────────────────────────────────────────
IO.puts("═" |> String.duplicate(72))
IO.puts("HPC benchmark reproduction (mirrors examples/benchmark_hpc.livemd)")
IO.puts("  Elixir #{System.version()}   OTP #{:erlang.system_info(:otp_release)}")
IO.puts("  cwd: #{File.cwd!()}")

full? = System.get_env("DIAG_FULL") in ["true", "1", "yes"]
extended? = System.get_env("DIAG_EXTENDED_DEBUG") in ["true", "1", "yes"]

if full? do
  IO.puts("  MODE: FULL (§7 exact replica — run_benchmark waits + collects; LONG)")
else
  IO.puts("  MODE: DIAG (sync + upload checksum-verify + submit smoke; quick)")
end

if extended? do
  IO.puts("  extended_debug: ON (every ssh/scp/upload command is printed)")
end

IO.puts("═" |> String.duplicate(72))

# ─────────────────────────────────────────────────────────────────────────────
# §1 configure paths from .env
# ─────────────────────────────────────────────────────────────────────────────
env_file = Path.expand("./.env", File.cwd!())
AtpBenchmarkRunner.load_env!(env_file)

IO.puts("\n[§1] .env: #{env_file}")
IO.puts("  TPTP_ROOT=#{AtpBenchmarkRunner.tptp_dir()}")
IO.puts("  Store=#{AtpBenchmarkRunner.store_dir()}")

IO.puts(
  "  steady=#{System.get_env("HPC_CONNECT_STEADY_CONNECTION")} retry_forever=#{System.get_env("HPC_CONNECT_RETRY_FOREVER")}"
)

# ─────────────────────────────────────────────────────────────────────────────
# §2 bootstrap the HPC session
# ─────────────────────────────────────────────────────────────────────────────
boot =
  DiagRepro.step("§2 HpcConnect.bootstrap", fn ->
    HpcConnect.bootstrap(mode: :local, env_file: env_file)
  end)

if match?({:error, _, _}, boot) do
  IO.puts("FATAL: bootstrap failed — aborting")
  System.halt(1)
end

session = boot.session
IO.puts("\n  cluster=#{session.cluster.name} alias=#{session.ssh_alias} user=#{session.username}")
IO.puts("  steady: #{DiagRepro.steady_state(session)}")

# ─────────────────────────────────────────────────────────────────────────────
# §2b/§3 provers + problems (same 14 as the notebook)
# ─────────────────────────────────────────────────────────────────────────────
selected_provers = [
  :tableaux,
  :shot_tx,
  :eprover,
  :vampire,
  :cvc5,
  :zipperposition,
  :leo3,
  :leo2,
  :lash
]

selected_names = [
  "ALG001+0.p",
  "GRP001-0.p",
  "GRP002+0.p",
  "GRP003+0.p",
  "GRP004+0.p",
  "GRP720+1.p",
  "GRP752-1.p",
  "LAT001+0.p",
  "PUZ001+0.p",
  "REL001+0.p",
  "SET001^0.p",
  "SMT001+0.p",
  "SYN000+0.p",
  "THF001+0.p"
]

problems =
  DiagRepro.step("§3 select_problems (14 names)", fn ->
    # Same call as the notebook; in `mix run` the name index does not resolve
    # bundled examples, so fall back to the bundled set (like run_hpc_benchmark.exs).
    case AtpBenchmarkRunner.select_problems(names: selected_names, limit: 10) do
      [] ->
        bundled = AtpBenchmarkRunner.TPTP.bundled_examples()

        Enum.filter(bundled, fn p ->
          (p.name || p.id || "") in selected_names
        end)

      found ->
        found
    end
  end)

if match?({:error, _, _}, problems) or problems == [] do
  IO.puts("FATAL: could not resolve problems")
  System.halt(1)
end

IO.puts("\n  #{length(problems)} problems resolved")

# ─────────────────────────────────────────────────────────────────────────────
# §6 build the HPC plan (single-node sequential, same as notebook §6)
# ─────────────────────────────────────────────────────────────────────────────
plan =
  DiagRepro.step("§6 AtpBenchmarkRunner.bootstrap (plan)", fn ->
    AtpBenchmarkRunner.bootstrap(
      session,
      selected_provers,
      problems,
      mode: :hpc,
      hpc_mode: :single_node,
      single_node_mode: :sequential,
      timeout_seconds: 30,
      wait_for_completion: false,
      prepare_images: false,
      extended_debug: extended?
    )
  end)

if match?({:error, _, _}, plan) do
  IO.puts("FATAL: could not build plan")
  System.halt(1)
end

IO.puts(
  "\n  Run ID: #{plan.id}  provers=#{length(plan.provers)} problems=#{length(plan.problems)}"
)

hpc = plan.metadata[:hpc] || %{}
remote_tptp_dir = hpc[:remote_tptp_dir]
IO.puts("  remote_tptp_dir=#{inspect(remote_tptp_dir)}")

# ─────────────────────────────────────────────────────────────────────────────
# §7a SYNC + upload checksum verification  (tests the malformed-upload hypothesis)
# ─────────────────────────────────────────────────────────────────────────────
sync_result =
  DiagRepro.step("§7a TPTPSync.sync_problem_set! (upload all 14 + conversions)", fn ->
    unless remote_tptp_dir do
      raise "no remote_tptp_dir in plan metadata"
    end

    AtpBenchmarkRunner.HPC.TPTPSync.sync_problem_set!(session, problems,
      remote_tptp_dir: remote_tptp_dir
    )
  end)

IO.puts("\n  steady after sync: #{DiagRepro.steady_state(session)}")

case sync_result do
  {:error, _, _} ->
    IO.puts("  ✗ sync failed — cannot checksum-verify")

  remote_problems ->
    DiagRepro.step("§7b checksum-verify uploads", fn ->
      results = DiagRepro.verify_uploads(session, remote_problems, remote_tptp_dir)

      ok = Enum.count(results, &match?({:ok, _}, &1))
      bad = Enum.count(results, &(not match?({:ok, _}, &1)))

      IO.puts("\n    uploads verified: #{ok} ok, #{bad} problem(s)")

      Enum.each(results, fn
        {:ok, name} ->
          IO.puts("      ✅ #{name}")

        {:mismatch, name, l, r, size} ->
          IO.puts("      ❌ MISMATCH #{name} (size=#{size}) local=#{l} remote=#{r}")

        {:missing, name} ->
          IO.puts("      ❌ MISSING remotely: #{name}")
      end)

      results
    end)
end

# ─────────────────────────────────────────────────────────────────────────────
# §7c submit smoke — replicates the sbatch submit without the 1h wait/collect
# ─────────────────────────────────────────────────────────────────────────────
DiagRepro.step("§7c submit smoke (sbatch + scancel)", fn ->
  {out, status} =
    HpcConnect.SSH.exec(
      session,
      "sbatch --parsable --partition=cpu --ntasks=1 --cpus-per-task=48 " <>
        "--job-name=abr_diag_repro --time=00:02:00 --wrap='hostname'",
      []
    )

  IO.puts("\n    sbatch status=#{status} out=#{inspect(String.trim(out))}")

  case Integer.parse(String.trim(out)) do
    {job_id, _} ->
      {out2, _} = HpcConnect.SSH.exec(session, "squeue -j #{job_id} -h -o '%i %T'", [])
      IO.puts("    squeue: #{inspect(String.trim(out2))}")
      {_, _} = HpcConnect.SSH.exec(session, "scancel #{job_id}", [])
      IO.puts("    scancelled #{job_id}")
      {:submitted, job_id}

    :error ->
      IO.puts("    ⚠ no job id — submit path may be broken")
      {:error, out}
  end
end)

# ─────────────────────────────────────────────────────────────────────────────
# §7 exact replica (only with DIAG_FULL=true) — waits + collects (LONG)
# ─────────────────────────────────────────────────────────────────────────────
if full? do
  IO.puts("\n[§7 FULL] run_benchmark(plan) — exact notebook replica (long)")

  {t_ms, results} =
    :timer.tc(fn ->
      try do
        AtpBenchmarkRunner.run_benchmark(plan)
      rescue
        e ->
          IO.puts("Benchmark failed: #{Exception.message(e)}")
          IO.puts(Exception.format(:error, e, __STACKTRACE__))
          []
      end
    end)

  IO.puts(
    "\nBenchmark finished in #{Float.round(t_ms / 1_000_000, 2)}s, results=#{length(results)}"
  )
else
  IO.puts("\n(skipping §7 full run — set DIAG_FULL=true for the exact §7 replica)")
end

# ─────────────────────────────────────────────────────────────────────────────
# §7 quick full (DIAG_QUICK_FULL=true) — sync + submit + WAIT + COLLECT on a
# reduced 2-problem set, so the wait/collect phase (not covered by DIAG mode)
# is exercised end-to-end in ~1-2 min instead of ~1 h.
# ─────────────────────────────────────────────────────────────────────────────
if System.get_env("DIAG_QUICK_FULL") in ["true", "1", "yes"] do
  IO.puts("\n[§7 QUICK-FULL] reduced run_benchmark (2 problems, wait+collect)")

  easy_names = ["GRP001-0.p", "PUZ001-0.p"]
  easy_problems = Enum.filter(problems, fn p -> (p.name || p.id) in easy_names end)

  quick_plan =
    AtpBenchmarkRunner.bootstrap(
      session,
      [:shot_tx, :eprover],
      easy_problems,
      mode: :hpc,
      hpc_mode: :single_node,
      single_node_mode: :sequential,
      timeout_seconds: 20,
      wait_for_completion: false,
      prepare_images: false,
      extended_debug: extended?
    )

  {qt, qresults} =
    :timer.tc(fn ->
      try do
        AtpBenchmarkRunner.run_benchmark(quick_plan)
      rescue
        e ->
          IO.puts("Quick full failed: #{Exception.message(e)}")
          IO.puts(Exception.format(:error, e, __STACKTRACE__))
          []
      end
    end)

  IO.puts(
    "\nQuick full finished in #{Float.round(qt / 1_000_000, 2)}s, results=#{length(qresults)}"
  )

  Enum.each(qresults, fn r ->
    IO.puts("  #{r.problem_id} / #{r.prover} -> #{r.szs_status}")
  end)
else
  IO.puts("\n(set DIAG_QUICK_FULL=true to also run a reduced wait+collect benchmark)")
end

IO.puts("\n  final steady: #{DiagRepro.steady_state(session)}")
IO.puts("\nDONE.")
