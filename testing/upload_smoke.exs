# Smoke: prove problem uploads now ride the steady shell via base64 (no scp).
# This is the exact path TPTPSync uses after the scp→base64 change.
# Run with:  mix run testing/upload_smoke.exs
alias AtpBenchmarkRunner.HPC.RemoteFiles

env_file = Path.expand("./.env", File.cwd!())
AtpBenchmarkRunner.load_env!(env_file)

boot = HpcConnect.bootstrap(mode: :local, env_file: env_file)
session = boot.session

IO.puts(
  "cluster=#{session.cluster.name} steady=#{session.steady_connection} retry_forever=#{session.retry_forever}"
)

IO.puts("")

# Local temp file with CRLF endings (Windows) — must come back LF on the cluster.
local = Path.join(System.tmp_dir!(), "abr_upload_smoke_#{System.unique_integer([:positive])}.txt")
File.write!(local, "line1\r\nline2\r\nline3\r\n")

remote = "#{session.work_dir}/abr_upload_smoke_#{System.unique_integer([:positive])}.txt"
IO.puts("uploading #{Path.basename(local)} -> #{remote}")

t0 = System.monotonic_time(:millisecond)
:ok = RemoteFiles.upload_file!(session, local, remote)
IO.puts("upload ok in #{System.monotonic_time(:millisecond) - t0} ms (steady shell, no scp)")

back = RemoteFiles.read_text!(session, remote)
IO.puts("read back: #{inspect(back)}")
IO.puts("LF normalized? #{not String.contains?(back, "\r")}")

# Cleanup
HpcConnect.SSH.exec(session, "rm -f #{HpcConnect.Shell.escape(remote)}", [])
File.rm!(local)
IO.puts("cleaned up")

if String.contains?(back, "\r") do
  IO.puts("FAIL: CRLF not normalized")
  System.halt(1)
end

if back != "line1\nline2\nline3\n" do
  IO.puts("FAIL: content mismatch")
  System.halt(1)
end

IO.puts("OK")
