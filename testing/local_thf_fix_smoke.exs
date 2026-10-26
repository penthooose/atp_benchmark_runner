# Local smoke test for the THF / include input fix.
#
#   mix run testing/local_thf_fix_smoke.exs
#
# Part A shows what the old input preparation produced (the defect), part B shows
# what each prover is prepared with now, part C actually runs the affected local
# images so the fix is confirmed by verdicts, not by inspection.

AtpBenchmarkRunner.load_env!(".env")

alias AtpBenchmarkRunner.{Input, LocalRunner, Problem}
alias AtpBenchmarkRunner.TPTP.{Dialect, Includes, ToTHF}

root = AtpBenchmarkRunner.tptp_dir()
staging = Path.join(System.tmp_dir!(), "atp_thf_fix_smoke")

File.rm_rf(staging)
File.mkdir_p!(staging)

# Library copy first, bundled smoke example second: THF001+0 is not a real TPTP
# problem, so it only exists under priv/tptp_examples.
resolve = fn name ->
  case AtpBenchmarkRunner.resolve_tptp_name(name) do
    nil ->
      bundled = Path.join([:code.priv_dir(:atp_benchmark_runner), "tptp_examples", name])
      if File.exists?(bundled), do: bundled, else: raise("cannot resolve #{name} (root #{root})")

    path ->
      path
  end
end

problem = fn name -> Problem.from_tptp_file(resolve.(name)) end

section = fn title ->
  IO.puts("\n=== #{title} " <> String.duplicate("=", max(0, 60 - String.length(title))))
end

# --- Part A: the defect, reproduced on the inputs the old code fed provers ----

section.("A. What the OLD code fed the provers")

thf = problem.("THF001+0.p")
old_thf = Path.join(staging, "THF001+0_old_lash_thf.p")
File.write!(old_thf, ToTHF.convert_string(File.read!(thf.path)))

IO.puts("THF001+0.p (native THF) -> old Lash-flavour conversion")
IO.puts("  byte-identical to the problem: #{File.read!(old_thf) == File.read!(thf.path)}")
IO.puts("  keeps lambda (^): #{String.contains?(File.read!(old_thf), "^")}")
IO.puts("  keeps application (@): #{String.contains?(File.read!(old_thf), "@")}")
IO.puts("  bytes: #{File.stat!(thf.path).size} -> #{File.stat!(old_thf).size}")

grp = problem.("GRP001-1.p")
{:ok, grp_dialect} = Dialect.detect(grp.path, path: grp.path)

{:ok, prepared_grp} = Input.prepare(:vampire, grp)

count = fn path ->
  path
  |> File.read!()
  |> then(&Regex.scan(~r/^(?:cnf|fof|tff|thf)\(/m, &1))
  |> length()
end

IO.puts("")
IO.puts("GRP001-1.p (#{grp_dialect.label}) uses includes: #{Includes.includes?(grp.path)}")
IO.puts("  raw problem: #{File.stat!(grp.path).size} bytes, #{count.(grp.path)} statements")

IO.puts(
  "  expanded   : #{File.stat!(prepared_grp.path).size} bytes, " <>
    "#{count.(prepared_grp.path)} statements (axioms inlined)"
)

# --- Part B: what each prover is prepared with now ---------------------------

section.("B. What the fix feeds each prover")

pairs = [
  {:shot_tx, "THF001+0.p"},
  {:lash, "THF001+0.p"},
  {:cvc5, "THF001+0.p"},
  {:cvc5, "SET001^0.p"},
  {:vampire, "GRP001-1.p"},
  {:eprover, "GRP001-1.p"},
  {:shot_tx, "GRP001-1.p"},
  {:vampire, "GRP001-0.p"}
]

Enum.each(pairs, fn {prover, name} ->
  target = problem.(name)

  case Input.prepare(prover, target) do
    {:ok, prepared} ->
      IO.puts(
        "  #{prover} #{name}: #{prepared.kind} (#{prepared.dialect.label}) " <>
          "-> #{Path.basename(prepared.path)}"
      )

    {:skip, skip} ->
      IO.puts("  #{prover} #{name}: SKIP #{skip.status}: #{skip.reason}")
  end
end)

# --- Part C: run the affected images ----------------------------------------

section.("C. Running the affected prover images")

runs = [
  {:shot_tx, "THF001+0.p"},
  {:lash, "THF001+0.p"},
  {:shot_tx, "GRP001-1.p"},
  {:vampire, "GRP001-1.p"},
  {:eprover, "GRP001-1.p"},
  {:vampire, "GRP001-0.p"},
  {:cvc5, "SET001^0.p"}
]

Enum.each(runs, fn {prover, name} ->
  target = problem.(name)

  IO.puts("  #{prover} #{name} ...")

  {:ok, result} = {:ok, LocalRunner.run_single(prover, target, timeout_seconds: 60)}

  IO.puts(
    "    status=#{result.szs_status} wall=#{result.wall_time_ms}ms " <>
      "input=#{get_in(result.metadata, [:input_kind]) || "-"} " <>
      "dialect=#{get_in(result.metadata, [:dialect]) || "-"}"
  )

  if result.szs_status == "InputError" do
    IO.puts("    reason: #{result.metadata[:reason]}")
  end
end)

section.("done")
