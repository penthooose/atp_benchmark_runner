# Smoke test: verify HTTPS + TPTP archive download works
#
# Run with: mix run test/tptp_download_smoke.exs

IO.puts("=== TPTP Download Smoke Test ===")
IO.puts("")

transport_opts = [verify: :verify_none]

urls = [
  {"tptp.org homepage", "https://tptp.org/"},
  {"TPTP archive", "https://tptp.org/TPTP/Distribution/TPTP-v9.2.1.tgz"}
]

Enum.each(urls, fn {label, url} ->
  IO.puts("Testing #{label} (#{url})")

  req = Req.new(url: url, connect_options: [transport_opts: transport_opts])
  result = Req.request(req)
  IO.puts("  result: #{inspect(elem(result, 0))}")

  case result do
    {:ok, %{status: s}} when s in 200..399 ->
      IO.puts("  ✅ OK (HTTP #{s})")

    {:ok, %{status: s}} ->
      IO.puts("  ⚠️  HTTP #{s}")

    {:error, reason} ->
      IO.puts("  ❌ #{inspect(reason)}")
  end

  IO.puts("")
end)

IO.puts("=== Done ===")
