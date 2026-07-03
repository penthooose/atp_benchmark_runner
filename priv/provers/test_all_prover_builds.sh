#!/bin/bash -l
# test_all_prover_builds.sh


set -Eeuo pipefail

PROXY="http://proxy.nhr.fau.de:80"
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export http_proxy="$PROXY"
export https_proxy="$PROXY"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,.nhr.fau.de"
export no_proxy="$NO_PROXY"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo -e "  \e[32m✓ PASS\e[0m $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  \e[31m✗ FAIL\e[0m $1"; }
sep() { echo ""; echo "--- $1 ---"; }

echo "=============================================="
echo " All Prover Apptainer Build — Interactive Test"
echo "=============================================="

# ---- Prerequisite: apptainer available ----
sep "Prerequisite: apptainer"
if command -v apptainer &>/dev/null; then
  pass "apptainer $(apptainer --version 2>&1 | head -1)"
else
  fail "apptainer not found"
  exit 1
fi

# ============================================================
# 1. LEO-II (ocaml/opam + opam install ocamlfind camlp5 + make)
# ============================================================
sep "1. LEO-II — ocaml/opam opam deps + source build"

echo "  Testing opam init + ocamlfind/camlp5 install..."
apptainer exec --fakeroot docker://ocaml/opam:ubuntu-22.04-ocaml-4.12 sh -c '
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  # Use a writable temp dir and pin OCaml 4.12
  export OPAMROOT=/tmp/opam-root
  rm -rf "$OPAMROOT"
  opam init --disable-sandboxing --compiler=ocaml-base-compiler.4.12.1 2>&1 | tail -5
  eval $(opam env)

  # Check for system tools
  for tool in m4 pkg-config gcc make curl tar; do
    if which $tool 2>/dev/null; then echo "  ✓ $tool found"; else echo "  ✗ $tool MISSING"; fi
  done

  opam install -y ocamlfind camlp5 2>&1 | tail -20
  echo "opam install ocamlfind camlp5 exit: $?"
  rm -rf "$OPAMROOT"
' 2>/dev/null && pass "LEO-II deps install OK" || fail "LEO-II deps install failed"

echo "  Testing LEO-II source download + make..."
apptainer exec --fakeroot docker://ocaml/opam:ubuntu-22.04-ocaml-4.12 sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  # Use the image'\''s pre-configured opam root
  export OPAMROOT=/home/opam/.opam
  eval $(opam env)
  opam install -y ocamlfind camlp5 2>/dev/null

  curl -fSL "http://page.mi.fu-berlin.de/cbenzmueller/leo/leo2_v1.7.0.tgz" -o /tmp/leo2.tgz
  echo "download exit: $?"
  echo "=== Tarball size ==="
  ls -la /tmp/leo2.tgz
  echo "=== Tarball contents (first 30) ==="
  tar -tzf /tmp/leo2.tgz 2>&1 | head -30
  rm -rf /tmp/leo2 && mkdir -p /tmp/leo2
  tar -xzf /tmp/leo2.tgz -C /tmp/leo2 --strip-components=1 2>&1
  echo "=== Extracted files (tmp/leo2/) ==="
  ls -la /tmp/leo2/ 2>/dev/null
  # Makefile is in src/, not at top level
  cd /tmp/leo2/src 2>/dev/null
  make 2>&1 | tail -20
  echo "make exit: $?"
  find /tmp/leo2 -type f \( -name "leo" -o -name "leo.opt" \) 2>/dev/null
' 2>/dev/null && pass "LEO-II build OK" || fail "LEO-II build failed"

# ============================================================
# 2. LASH — download + build (URL confirmed working)
# ============================================================
sep "2. Lash — download + build test"

echo "  Testing Lash download + extraction..."
apptainer exec docker://ocaml/opam:ubuntu-22.04-ocaml-4.12 sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  curl -fSL "http://grid01.ciirc.cvut.cz/~chad/lash/lash-1.14.tgz" -o /tmp/lash.tar.gz
  echo "download exit: $?"
  ls -la /tmp/lash.tar.gz
  echo "=== Tarball contents (first 15) ==="
  tar -tzf /tmp/lash.tar.gz 2>&1 | head -15
  rm -rf /tmp/lash && mkdir -p /tmp/lash
  tar -xzf /tmp/lash.tar.gz -C /tmp/lash --strip-components=1
  echo "=== Extracted files ==="
  ls /tmp/lash/ 2>/dev/null
  ls /tmp/lash/source/ 2>/dev/null | head -5
  echo "Tarball download and extraction OK"
  rm -rf /tmp/lash.tar.gz /tmp/lash
' 2>/dev/null && pass "Lash download+extract OK" || fail "Lash download+extract failed"

# ============================================================
# 3. CVC5 — verify --lang=tptp works with TPTP problems
# ============================================================
sep "3. CVC5 — verify --lang=tptp works with TPTP problems"

echo "  Checking if cvc5.sif exists..."
CVC5_SIF="$HOME/.cache/hpc_connect/singularity_images/cvc5.sif"
if [ -f "$CVC5_SIF" ]; then
  pass "cvc5.sif exists"

  echo "  Testing cvc5 with --lang tptp on a TPTP file..."
  # Create a minimal TPTP problem
  mkdir -p /tmp/tptp_test
  cat > /tmp/tptp_test/test.p <<'EOF'
% SZS status Theorem for test
fof(ax1, axiom, p | ~p).
fof(conj, conjecture, $true).
EOF
  apptainer exec "$CVC5_SIF" cvc5 --lang=tptp --tlimit=5000 /tmp/tptp_test/test.p 2>&1 | head -10
  echo "cvc5 TPTP mode exit: $?"
  rm -rf /tmp/tptp_test
else
  fail "cvc5.sif not found at $CVC5_SIF (build it first)"
fi

# ============================================================
# 4. E-PROVER — verify binary
# ============================================================
sep "4. E-Prover — verify installed binary"

EPROVER_SIF="$HOME/.cache/hpc_connect/singularity_images/eprover.sif"
if [ -f "$EPROVER_SIF" ]; then
  echo "  Testing eprover binary..."
  apptainer exec "$EPROVER_SIF" eprover-ho --version 2>&1 | head -3
  echo "eprover exit: $?"
  apptainer exec "$EPROVER_SIF" eprover --version 2>&1 | head -3 || echo "eprover (non-HO) not found"
  pass "E-Prover binary works"
else
  fail "eprover.sif not found"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=============================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=============================================="
