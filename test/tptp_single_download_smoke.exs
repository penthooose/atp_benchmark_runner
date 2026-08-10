# Smoke test: single-problem download from the official TPTP SeeTPTP CGI
# (https://tptp.org/cgi-bin/SeeTPTP) without downloading the full archive.
#
# Run with: mix run test/tptp_single_download_smoke.exs
#
# Verifies against the live server:
#   1. An officially-published problem (GRP001-1.p in TPTP v9.3.0) downloads
#      and its HTML <pre> wrapper + anchors are stripped.
#   2. Bundled smoke names (GRP001-0.p, GRP002+0.p, LAT001+0.p) are NOT in the
#      current official release. By DEFAULT the local fallback resolves them
#      from the bundled examples (auto-copied from priv/tptp_examples into the
#      bundled tmp dir) — usable, but never written into the Problems/ layout.
#      `bundled_fallback: false` gives strict server-only behavior (warn + skip).

IO.puts("=== TPTP Single-Problem Download Smoke Test ===")
IO.puts("")

alias AtpBenchmarkRunner.TPTP.Downloader

# Use a throwaway tmp root so the test never touches the real ./tmp.
tmp_root = Path.join(System.tmp_dir!(), "atp_single_dl_smoke")
File.rm_rf!(tmp_root)

names = ["GRP001-0.p", "GRP002+0.p", "LAT001+0.p"]

# ── 1. Download an officially-published problem ──────────────────────────────
IO.puts("1. Downloading officially-published problem GRP001-1.p ...")
IO.puts("   URL: #{Downloader.single_problem_url("GRP001-1.p")}")

case Downloader.fetch_single_problem("GRP001-1.p") do
  {:ok, content} ->
    IO.puts("   ✅ fetched #{byte_size(content)} bytes")
    IO.puts("   First lines:")
    content |> String.split("\n") |> Enum.take(6) |> Enum.each(&IO.puts("     #{&1}"))

    IO.puts(
      "   Contains formula body: #{String.contains?(content, "cnf(square_element,hypothesis,")}"
    )

  {:error, reason} ->
    IO.puts("   ❌ #{inspect(reason)}")
end

IO.puts("")

# ── 2. Confirm the bundled smoke names are NOT in the current release ────────
IO.puts("2. Checking bundled smoke names against the current official release:")

Enum.each(names, fn name ->
  case Downloader.fetch_single_problem(name) do
    {:ok, _content} ->
      IO.puts("   #{name}: ✅ present in current official release")

    {:error, {:not_found, _}} ->
      IO.puts("   #{name}: ⚠️  not in current official release")
  end
end)

IO.puts("")

# ── 3. Default behavior: local fallback resolves bundled smoke names ─────────
IO.puts("3. Default download_tptp_problems! (server + local bundled fallback):")
IO.puts("   (missing on server but in priv/tptp_examples -> usable from bundled tmp dir)")

{problems, warnings} = AtpBenchmarkRunner.download_tptp_problems!(names, root_dir: tmp_root)

IO.puts("   resolved: #{length(problems)}   warnings: #{length(warnings)}")

Enum.each(problems, fn problem ->
  IO.puts(
    "   ✅ #{problem.name}  status=#{problem.expected_status}  " <>
      "rating=#{problem.rating}  path=#{problem.path}"
  )
end)

Enum.each(warnings, fn warning ->
  IO.puts("   ⚠️  #{warning.name}: #{inspect(warning.reason)}")
end)

# Verify nothing was written into the archive-consistent Problems/ layout.
problems_polluted? =
  Enum.any?(names, fn name ->
    File.exists?(Downloader.problem_target(name, root_dir: tmp_root))
  end)

IO.puts("   any stub written into Problems/: #{problems_polluted?}")

IO.puts("")

# ── 4. Strict server-only mode ───────────────────────────────────────────────
IO.puts("4. Strict server-only (bundled_fallback: false):")
IO.puts("   (missing names are warned + skipped, nothing written)")

{problems_strict, warnings_strict} =
  AtpBenchmarkRunner.download_tptp_problems!(names,
    root_dir: tmp_root,
    bundled_fallback: false
  )

IO.puts("   resolved: #{length(problems_strict)}   warnings: #{length(warnings_strict)}")

Enum.each(warnings_strict, fn warning ->
  IO.puts("   ⚠️  #{warning.name}: #{inspect(warning.reason)}")
end)

IO.puts("")

# ── 5. All resolved problems are usable (files exist on disk) ───────────────
IO.puts("5. Usability check:")

IO.puts(
  "   default-resolved files exist on disk: #{Enum.count(problems, &File.exists?(&1.path))}/#{length(problems)}"
)

IO.puts("")

IO.puts("=== Done ===")
