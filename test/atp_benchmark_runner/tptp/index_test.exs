defmodule AtpBenchmarkRunner.TPTP.IndexTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.TPTP.Index

  test "generated derivative files are never listed as problems" do
    dir = Path.join(System.tmp_dir!(), "atp_index_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Problems/GRP"))

    File.write!(Path.join(dir, "Problems/GRP/GRP001-0.p"), "cnf(a, axiom, p).\n")
    File.write!(Path.join(dir, "Problems/GRP/GRP001-0_thf.p"), "thf(a, axiom, p).\n")
    File.write!(Path.join(dir, "Problems/GRP/GRP001-0.smt2"), "(assert true)\n")

    File.write!(
      Path.join(dir, "Problems/GRP/GRP001-0_abc123_expanded.p"),
      "cnf(a, axiom, p).\n"
    )

    on_exit(fn -> File.rm_rf(dir) end)

    files = Index.list_files(root_dir: dir)
    names = Enum.map(files, &Path.basename/1)

    assert names == ["GRP001-0.p"]
  end
end
