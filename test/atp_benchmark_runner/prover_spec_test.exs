defmodule AtpBenchmarkRunner.ProverSpecTest do
  # Config-driven registry touches global :persistent_term state, so run
  # serially to avoid interleaving with other files that resolve provers.
  use ExUnit.Case, async: false

  alias AtpBenchmarkRunner.{Input, LocalRunner, Problem, Prover, Provers, Result}
  alias AtpBenchmarkRunner.Prover.Spec

  @prover_names ~w(cvc5 eprover lash leo2 leo3 shot_tx tableaux vampire zipperposition)a

  describe "config-driven registry" do
    test "discovers every prover from priv/provers/*/prover.exs" do
      assert Enum.sort(Provers.names()) == @prover_names
      assert Enum.map(Provers.all(), & &1.name) |> Enum.sort() == @prover_names
    end

    test "loads per-prover behavior hooks from the spec" do
      assert %Prover{input: :smt2, parser: :smt_bare} = Prover.builtin!(:cvc5)
      assert %Prover{input: :thf, parser: :szs} = Prover.builtin!(:lash)
      assert %Prover{input: :tptp, parser: :szs} = Prover.builtin!(:vampire)
      assert Prover.builtin!(:lash).supports.requires_conjecture? == true
      assert Prover.builtin!(:vampire).supports.requires_conjecture? == false
    end

    test "aliases resolve to canonical provers (atom and binary)" do
      assert Prover.builtin!(:zipperpin).name == :zipperposition
      assert Prover.builtin!("zipper_position").name == :zipperposition
      assert Prover.builtin!("e").name == :eprover
      assert Prover.builtin!(:e_prover).name == :eprover
      assert Prover.builtin!(:leo_iii).name == :leo3
      assert Prover.builtin!(:leo_ii).name == :leo2
      assert Prover.builtin!("simple_tableaux_solver").name == :tableaux
      assert Prover.builtin!(:shot).name == :shot_tx
      assert Prover.builtin!("shot-tx").name == :shot_tx
    end

    test "unknown names still resolve to :error without creating atoms" do
      assert Provers.fetch("nonexistent_prover_xyz") == :error
      refute Prover.builtin("nonexistent_prover_xyz")
    end

    test "container metadata is available per prover" do
      container = Provers.container!(:vampire)
      assert container.def_path =~ "vampire"
      assert container.docker_image =~ "atp-vampire"
      assert container.dockerfile_path =~ "vampire"
      assert Spec.load_all().containers |> map_size() == length(@prover_names)
    end

    test "all specs pass validation" do
      assert Provers.validate() == []
    end

    test "derives sif_name and image_name from the prover name" do
      assert Prover.builtin!(:vampire).sif_name == "vampire"
      assert Provers.container!(:vampire).image_name == "vampire"
      # tableaux is the one prover whose SIF/image name differs from its atom.
      assert Prover.builtin!(:tableaux).sif_name == "simple_tableaux_solver"
      assert Provers.container!(:tableaux).image_name == "simple_tableaux_solver"
      # shot_tx derives both from its name (no override in the spec).
      assert Prover.builtin!(:shot_tx).sif_name == "shot_tx"
      assert Provers.container!(:shot_tx).image_name == "shot_tx"
    end

    test "config declares the in-house prover and local execution mode" do
      # `our_prover: true` in the shot_tx spec drives Report/Compare defaults.
      assert Provers.our_prover() == :shot_tx
      assert Prover.builtin!(:shot_tx).our_prover
      refute Prover.builtin!(:tableaux).our_prover

      # `local_execution: :escript` (tableaux) vs the container default.
      assert Prover.builtin!(:tableaux).local_execution == :escript
      assert Prover.builtin!(:shot_tx).local_execution == :container
      assert Prover.builtin!(:vampire).local_execution == :container
    end

    test "a spec with an invalid local_execution or our_prover is rejected" do
      dir = Spec.specs_dir()
      tmp_name = "zzz_invalid_mode_prover"

      try do
        tmp_dir = Path.join(dir, tmp_name)
        File.mkdir_p!(tmp_dir)

        File.write!(
          Path.join(tmp_dir, "prover.exs"),
          ~s(%{name: :zzz_invalid_mode, local_execution: :binary, our_prover: "yes", command_template: "x {problem}", container: %{def_path: "a", dockerfile_path: "b", docker_image: "c"}})
        )

        assert {:error, reason} = Spec.load(tmp_name)
        assert reason =~ "local_execution" or reason =~ "our_prover"
      after
        File.rm_rf!(Path.join(dir, tmp_name))
      end
    end

    test "a spec file with an unknown key is rejected" do
      dir = Spec.specs_dir()
      tmp_name = "zzz_invalid_key_prover"

      try do
        tmp_dir = Path.join(dir, tmp_name)
        File.mkdir_p!(tmp_dir)

        File.write!(
          Path.join(tmp_dir, "prover.exs"),
          ~s(%{name: :zzz_invalid_key, legacy?: true, command_template: "x {problem}", container: %{def_path: "a", dockerfile_path: "b", docker_image: "c"}})
        )

        assert {:error, reason} = Spec.load(tmp_name)
        assert reason =~ "unknown key"
      after
        File.rm_rf!(Path.join(dir, tmp_name))
      end
    end

    test "a spec file that references an unknown placeholder is rejected" do
      dir = Spec.specs_dir()
      tmp_name = "zzz_invalid_placeholder_prover"

      try do
        tmp_dir = Path.join(dir, tmp_name)
        File.mkdir_p!(tmp_dir)

        File.write!(
          Path.join(tmp_dir, "prover.exs"),
          ~s(%{name: :zzz_invalid, command_template: "apptainer exec {sif_path} x {bogus}", container: %{image_name: "x", def_path: "a", dockerfile_path: "b", docker_image: "c"}})
        )

        assert {:error, reason} = Spec.load(tmp_name)
        assert reason =~ "unknown placeholder"
      after
        # Removing the dir restores the registry fingerprint; the invalid prover
        # was only ever loaded directly and never entered the cached registry.
        File.rm_rf!(Path.join(dir, tmp_name))
      end
    end
  end

  describe "Result.parse_for/2" do
    test "parses standard SZS status" do
      assert Result.parse_for(:szs, "% SZS status Theorem\n") == "Theorem"

      assert Result.parse_for(:smt_bare, "% SZS status CounterSatisfiable\n") ==
               "CounterSatisfiable"
    end

    test "maps bare SMT-LIB answers to SZS" do
      assert Result.parse_for(:smt_bare, "unsat\n") == "Unsatisfiable"
      assert Result.parse_for(:smt_bare, "sat\n") == "Satisfiable"
      assert Result.parse_for(:smt_bare, "unknown\n") == "Unknown"
    end

    test "falls back to SZS extraction when no bare answer is present" do
      assert Result.parse_for(:smt_bare, "%% some noise\n% SZS status Theorem\n") == "Theorem"
    end

    test "Result.from_output resolves the parser from the prover" do
      assert Result.from_output(Prover.builtin!(:cvc5), "GRP001-0", "unsat\n").szs_status ==
               "Unsatisfiable"

      assert Result.from_output(:vampire, "GRP001-0", "% SZS status Theorem\n").szs_status ==
               "Theorem"
    end
  end

  describe "Input.remote_input_path/2" do
    test "uses raw .p for :tptp provers" do
      assert Input.remote_input_path(Prover.builtin!(:vampire), "/remote/GRP001-0.p") ==
               "/remote/GRP001-0.p"
    end

    test "maps :smt2 to a .smt2 path" do
      assert Input.remote_input_path(Prover.builtin!(:cvc5), "/remote/GRP001-0.p") ==
               "/remote/GRP001-0.smt2"
    end

    test "maps :thf to a _thf.p path" do
      assert Input.remote_input_path(Prover.builtin!(:lash), "/remote/GRP001-0.p") ==
               "/remote/GRP001-0_thf.p"
    end

    test "leaves non-TPTP extensions untouched" do
      assert Input.remote_input_path(Prover.builtin!(:cvc5), "/remote/GRP001-0.ax") ==
               "/remote/GRP001-0.ax"
    end
  end

  describe "LocalRunner.filter_compatible_problems/2" do
    test "filters by declared logic prefixes" do
      prover = %Prover{
        name: :synthetic_fol,
        label: "Synthetic FOL",
        command_template: "x {problem}",
        supports: %{forms: [:cnf, :fof], requires_conjecture?: false}
      }

      fol = Problem.new(%{id: "p1", name: "p1", logic: "FOF", path: "/x.p"})
      thf = Problem.new(%{id: "p2", name: "p2", logic: "THF", path: "/y.p"})

      assert LocalRunner.filter_compatible_problems(prover, [fol, thf]) == [fol]
    end

    test "skips no-conjecture satisfiable problems for refutation provers" do
      tmp =
        Path.join(System.tmp_dir!(), "atp_spec_compat_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      sat_no_conj = Path.join(tmp, "sat_no_conj.p")
      File.write!(sat_no_conj, "fof(ax, axiom, $true).\n")

      theorem = Path.join(tmp, "theorem.p")
      File.write!(theorem, "fof(conj, conjecture, $true).\n")

      thf_sat = Path.join(tmp, "thf_sat.p")
      File.write!(thf_sat, "thf(ax, axiom, $true).\n")

      prover = %Prover{
        name: :synthetic_refutation,
        label: "Synthetic Refutation",
        command_template: "x {problem}",
        supports: %{forms: :all, requires_conjecture?: true}
      }

      p1 =
        Problem.new(%{
          id: "sat",
          name: "sat",
          logic: "FOF",
          path: sat_no_conj,
          expected_status: "Satisfiable"
        })

      p2 =
        Problem.new(%{
          id: "thm",
          name: "thm",
          logic: "FOF",
          path: theorem,
          expected_status: "Theorem"
        })

      p3 =
        Problem.new(%{
          id: "thf",
          name: "thf",
          logic: "THF",
          path: thf_sat,
          expected_status: "Satisfiable"
        })

      kept = LocalRunner.filter_compatible_problems(prover, [p1, p2, p3])
      assert Enum.map(kept, & &1.id) |> Enum.sort() == ["thf", "thm"]
    end

    test "keeps everything for default supports" do
      prover = Prover.builtin!(:vampire)
      problem = Problem.new(%{id: "p1", name: "p1", logic: "THF", path: "/x.p"})
      assert LocalRunner.filter_compatible_problems(prover, [problem]) == [problem]
    end
  end
end
