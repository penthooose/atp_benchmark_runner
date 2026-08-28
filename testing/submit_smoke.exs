# Smoke: verify SLURM submission still works through the current steady-connection
# path (the exact mechanism `run_benchmark` uses to submit jobs on helma).
# Run with:  mix run testing/submit_smoke.exs
env_file = Path.expand("./.env", File.cwd!())
AtpBenchmarkRunner.load_env!(env_file)

boot = HpcConnect.bootstrap(mode: :local, env_file: env_file)
session = boot.session

IO.puts("cluster=#{session.cluster.name} steady=#{session.steady_connection}")
IO.puts("")

# 1) A plain remote command through the steady shell (proves SSH works).
{out, status} = HpcConnect.SSH.exec(session, "echo submit-smoke-ok; hostname", [])
IO.puts("echo via ssh: status=#{status} out=#{inspect(String.trim(out))}")

# 2) A real sbatch submission through the same path (helma CPU partition,
#    explicit cpus-per-task in a full NUMA domain).
{out2, status2} =
  HpcConnect.SSH.exec(
    session,
    "sbatch --parsable --partition=cpu --ntasks=1 --cpus-per-task=48 --job-name=abr_submit_smoke --time=00:02:00 --wrap='hostname'",
    []
  )

IO.puts("sbatch: status=#{status2} out=#{inspect(String.trim(out2))}")

job_id =
  case Integer.parse(String.trim(out2)) do
    {id, _} -> id
    :error -> nil
  end

if job_id do
  # 3) Confirm it shows up in squeue, then cancel it.
  {out3, _} = HpcConnect.SSH.exec(session, "squeue -j #{job_id} -h -o '%i %T %N'", [])
  IO.puts("squeue for job #{job_id}: #{inspect(String.trim(out3))}")

  {_, _} = HpcConnect.SSH.exec(session, "scancel #{job_id}", [])
  IO.puts("cancelled #{job_id}")
else
  IO.puts("NO VALID JOB ID RETURNED - sbatch output: #{inspect(out2)}")
end
