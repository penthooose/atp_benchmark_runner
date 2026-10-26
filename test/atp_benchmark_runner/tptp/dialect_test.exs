defmodule AtpBenchmarkRunner.TPTP.DialectTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.TPTP.Dialect

  @thf_th0 """
  %--------------------------------------------------------------------------
  % File     : THF001+0
  % Status   : Theorem
  % SPC      : TH0_THM_EQU_NAR
  %--------------------------------------------------------------------------
  thf(p_type, type, p: $o).
  thf(conj, conjecture, ( p )).
  """

  @cnf """
  %----
  % Status   : Unsatisfiable
  % SPC      : CNF_UNS_RFO_NEQ_HRN
  %----
  cnf(a, axiom, p).
  cnf(b, negated_conjecture, ~ p).
  """

  test "reads a CNF problem as :cnf" do
    assert {:ok, dialect} = Dialect.detect_string(@cnf)
    assert dialect.form == :cnf
    assert dialect.label == "CNF"
    assert dialect.status == :unsatisfiable
  end

  test "refines THF to the SPC form, which distinguishes TH0 from THF" do
    assert {:ok, dialect} = Dialect.detect_string(@thf_th0)
    assert dialect.form == :thf
    assert dialect.label == "TH0"
    assert dialect.status == :theorem
    assert dialect.spc.form == "TH0"
  end

  test "classifies a mixed file by its richest language" do
    # A THF problem whose included axiom set is first-order is still THF.
    content = """
    thf(a, axiom, ![X: $i]: ( f @ X )).
    tff(b, axiom, ![X: $i]: g(X)).
    fof(c, axiom, h).
    """

    assert {:ok, dialect} = Dialect.detect_string(content)
    assert dialect.form == :thf
    assert dialect.label == "THF"
  end

  test "detects TFF" do
    assert {:ok, dialect} = Dialect.detect_string("tff(a, axiom, ![X: $i]: p(X)).\n")
    assert dialect.form == :tff
    assert dialect.label == "TFF"
  end

  test "rejects input the TPTP grammar does not accept" do
    assert {:error, {:invalid, messages}} = Dialect.detect_string("this is not tptp")
    assert messages != []
  end

  test "accepts?/2 matches the dialect family" do
    {:ok, thf} = Dialect.detect_string(@thf_th0)
    {:ok, cnf} = Dialect.detect_string(@cnf)

    assert Dialect.accepts?([:thf], thf)
    assert Dialect.accepts?(["THF"], thf)
    assert Dialect.accepts?(["TH0", "TH1", "THF"], thf)
    refute Dialect.accepts?([], thf)
    refute Dialect.accepts?([:thf], cnf)
    assert Dialect.accepts?(:all, cnf)
  end

  test "normalize_accepts/1 rejects names that are not TPTP languages" do
    assert Dialect.normalize_accepts(["TH0", "THF"]) == [:thf]
    assert_raise ArgumentError, fn -> Dialect.normalize_accepts(["HOL"]) end
  end
end
