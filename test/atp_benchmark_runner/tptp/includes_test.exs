defmodule AtpBenchmarkRunner.TPTP.IncludesTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.TPTP.Includes

  setup do
    dir = Path.join(System.tmp_dir!(), "atp_includes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Problems/GRA"))
    File.mkdir_p!(Path.join(dir, "Axioms"))

    File.write!(
      Path.join(dir, "Axioms/GRA000+0.ax"),
      """
      %----
      % Status   : Satisfiable
      %----
      fof(ax_shared, axiom, shared_axiom).
      """
    )

    File.write!(
      Path.join(dir, "Axioms/GRA001+0.ax"),
      """
      include('Axioms/GRA000+0.ax').
      fof(ax_nested, axiom, nested_axiom).
      """
    )

    on_exit(fn -> File.rm_rf(dir) end)

    %{root: dir}
  end

  test "detects include directives" do
    path = write_problem(%{root: System.tmp_dir!()}, "fof(a, axiom, p).")
    assert Includes.includes?(path) == false

    path = write_including_problem(Path.join(System.tmp_dir!(), "x"))
    assert Includes.includes?(path)
  end

  test "reads the include names of a source text" do
    content = "include('Axioms/GRA000+0.ax').\ninclude('Axioms/GRA001+0.ax', [ax_nested]).\n"

    assert Includes.directive_names(content) == [
             "Axioms/GRA000+0.ax",
             "Axioms/GRA001+0.ax"
           ]
  end

  test "leaves a problem without includes untouched", %{root: root} do
    path = write_problem(%{root: root}, "fof(a, axiom, p).")

    assert {:ok, %{path: ^path, expanded?: false}} = Includes.expand(path, tptp_root: root)
  end

  test "expands nested includes into one self-contained problem", %{root: root} do
    path = write_including_problem(root)

    assert {:ok, %{path: expanded, expanded?: true, files: files}} =
             Includes.expand(path, tptp_root: root)

    content = File.read!(expanded)
    assert content =~ "shared_axiom"
    assert content =~ "ax_nested"
    refute content =~ "include("
    # The problem's own header survives verbatim, so status and SPC stay readable.
    assert content =~ "% Status   : Theorem"
    # The axiom file the include reached is part of the dependency set.
    assert Enum.any?(files, &String.ends_with?(&1, "GRA000+0.ax"))
  end

  test "reports an include that cannot be resolved instead of dropping it", %{root: root} do
    path =
      write_problem(%{root: root}, "include('Axioms/MISSING+0.ax').\nfof(a, axiom, p).\n")

    assert {:error, {:include_unresolved, messages}} = Includes.expand(path, tptp_root: root)
    assert Enum.any?(messages, &(&1 =~ "TPTP0601"))
  end

  test "reports a cyclic include graph", %{root: root} do
    File.write!(
      Path.join(root, "Axioms/CYC.ax"),
      "include('Axioms/CYC.ax').\nfof(c, axiom, c).\n"
    )

    path = write_problem(%{root: root}, "include('Axioms/CYC.ax').\nfof(a, axiom, p).\n")

    assert {:error, {:include_unresolved, messages}} = Includes.expand(path, tptp_root: root)
    assert Enum.any?(messages, &(&1 =~ "TPTP0602"))
  end

  test "gives the expanded copy a stable, collision-free name" do
    a = Includes.expanded_path("/tmp/a/GRP001-0.p")
    b = Includes.expanded_path("/tmp/b/GRP001-0.p")

    assert a == Includes.expanded_path("/tmp/a/GRP001-0.p")
    refute a == b
    assert String.ends_with?(a, "_expanded.p")
  end

  defp write_problem(%{root: root}, content) do
    path = Path.join(root, "Problems/GRA/GRA002+0.p")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp write_including_problem(root) do
    File.mkdir_p!(root)

    write_problem(%{root: root}, """
    %----
    % Status   : Theorem
    % SPC      : FOF_THM_RFO_SEQ
    %----
    include('Axioms/GRA001+0.ax').
    fof(goal, conjecture, shared_axiom).
    """)
  end
end
