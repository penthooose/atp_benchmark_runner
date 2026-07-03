#!/bin/bash -l
# test_all_prover_builds.sh
#
# Tests remaining ATP prover builds that still need debugging.
# Run on a FAU cluster login node (Alex, Fritz) with apptainer available.
# Remove the --debug flag once a prover passes.

set -Eeuo pipefail

PROXY="http://proxy.nhr.fau.de:80"
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export http_proxy="$PROXY"
export https_proxy="$PROXY"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,.nhr.fau.de"
export no_proxy="$NO_PROXY"

sep() { echo ""; echo "--- $1 ---"; }
info() { echo "  [INFO] $1"; }

echo "=============================================="
echo " ATP Prover Apptainer Build Tests"
echo " Tests LEO-II and Lash build pipeline steps."
echo " Date: $(date)"
echo "=============================================="

# ---- Prerequisite: apptainer available ----
sep "Prerequisite: apptainer"
if command -v apptainer &>/dev/null; then
  echo "  ✓ apptainer $(apptainer --version 2>&1 | head -1)"
else
  echo "  ✗ apptainer not found — are you on a cluster node?"
  exit 1
fi

# Test that docker:// pulls work (tested on Alex)
info "Testing docker pull..."
if apptainer exec docker://buildpack-deps:stable-curl sh -c 'echo ok' 2>/dev/null; then
  echo "  ✓ docker://buildpack-deps:stable-curl pull+exec"
else
  echo "  ✗ docker pull failed (check proxy)"
fi

# ============================================================
# 1. LEO-II — pkgconf + opam init + deps + source build
# ============================================================
# NOTE: Single apptainer exec per prover (--writable-tmpfs is per-call).
#       In %post, /home/opam/.opam exists; during exec we must init opam manually.

sep "1. LEO-II — pkgconf + opam + source build (single exec)"

apptainer exec --writable-tmpfs docker://ocaml/opam:ubuntu-22.04-ocaml-4.12 sh -c '
  set -ux
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"

  # Step 1a: compile pkgconf from source
  # Fix 1: reset PATH
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  hash -r

  cd /tmp && \
  curl -fSL "https://distfiles.ariadne.space/pkgconf/pkgconf-1.9.5.tar.gz" -o pkgconf.tar.gz && \
  tar --no-same-owner -xzf pkgconf.tar.gz && \
  cd pkgconf-1.9.5 && \
  ./configure --prefix=/usr/local && \
  make -j$(nproc) && \
  make install
  # pkgconf installs as /usr/local/bin/pkgconf, NOT pkg-config.
  # Create the symlink that opam's conf-pkg-config expects.
  # In rootless apptainer exec, /usr/local/bin may not be writable
  # (Permission denied). Fall back to /tmp with PATH override.
  if ln -sf /usr/local/bin/pkgconf /usr/local/bin/pkg-config 2>/dev/null; then
    echo "SYMLINK: /usr/local/bin/pkg-config -> pkgconf"
  else
    ln -sf /usr/local/bin/pkgconf /tmp/pkg-config 2>/dev/null || true
    export PATH="/tmp:$PATH"
    echo "SYMLINK: /tmp/pkg-config -> pkgconf (rootless fallback)"
  fi
  export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"
  export PATH="/usr/local/bin:$PATH"
  hash -r
  ldconfig -n /usr/local/lib 2>/dev/null || true
  echo "PKGCONF_VERSION: $(pkg-config --version 2>&1)"
  echo "PKG_CONFIG_WHICH: $(command -v pkg-config 2>&1)"
  echo "PKGCONF_WHICH: $(command -v pkgconf 2>&1)"
  # Extra symlink in /usr/bin as fallback
  ln -sf /usr/local/bin/pkgconf /usr/bin/pkg-config 2>/dev/null || true
  # Locate opam binary (not on default PATH after reset)
  OPAM_BIN="$(command -v opam 2>/dev/null || find /home/opam -name opam -type f 2>/dev/null | head -1)"
  if [ -n "$OPAM_BIN" ]; then
    export PATH="$(dirname "$OPAM_BIN"):$PATH"
    echo "OPAM_PATH: $(command -v opam)"
  fi

  # Step 1b: init opam and install deps
  export OPAMROOT=/tmp/opam-root
  rm -rf "$OPAMROOT"
  opam init --disable-sandboxing --compiler=ocaml-base-compiler.4.12.1 --yes 2>&1 | tail -3
  eval $(opam env)
  echo "OPAM_VERSION: $(opam --version 2>&1)"
  # Fix 3: opam env vars + force PATH
  export OPAMENV_IGNORE=false
  export OPAMROOTISOK=1
  export OPAMYES=1
  export PATH="/usr/local/bin:$PATH"
  hash -r
  echo "Pre-install pkg-config check: $(command -v pkg-config 2>/dev/null || echo MISSING)"
  opam install -y ocamlfind camlp5 camlp4 2>&1 | tail -10
  echo "OPAM_EXIT: $?"

  # Step 1c: download and build LEO-II
  curl -fSL "http://page.mi.fu-berlin.de/cbenzmueller/leo/leo2_v1.7.0.tgz" -o /tmp/leo2.tgz
  mkdir -p /opt/leo2
  tar -xzf /tmp/leo2.tgz -C /opt/leo2 --strip-components=1
  echo "EXTRACTED: $(ls /opt/leo2/ 2>/dev/null)"
  cd /opt/leo2/src
  make 2>&1 | tail -15
  candidate=$(find /opt/leo2 -type f \( -name "leo" -o -name "leo.opt" -o -name "leo.byte" \) 2>/dev/null | head -1)
  if [ -n "$candidate" ]; then
    echo "BINARY_FOUND: $candidate"
  else
    echo "NO_BINARY"
    echo "FILES_IN_SRC: $(ls /opt/leo2/src/ 2>/dev/null | head -20)"
  fi
' 2>&1 | grep -E "(PKGCONF_VERSION|OPAM_VERSION|OPAM_EXIT|BINARY_FOUND|NO_BINARY|error|Error|FATAL)" || true

# ============================================================
# 2. LASH — full build with opam init + ocamlyacc
# ============================================================
sep "2. Lash — full build with opam init (single exec)"

apptainer exec --writable-tmpfs docker://ocaml/opam:ubuntu-22.04-ocaml-4.12 sh -c '
  set -ux
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"

  # Init opam for ocamlyacc
  export OPAMROOT=/tmp/opam-root
  rm -rf "$OPAMROOT"
  opam init --disable-sandboxing --compiler=ocaml-base-compiler.4.12.1 --yes 2>&1 | tail -3
  eval $(opam env)
  echo "ocamlyacc: $(which ocamlyacc 2>/dev/null || echo NOT_FOUND)"

  # Download and build Lash
  curl -fSL "http://grid01.ciirc.cvut.cz/~chad/lash/lash-1.14.tgz" -o /tmp/lash.tar.gz
  mkdir -p /opt/lash
  tar --no-same-owner -xzf /tmp/lash.tar.gz -C /opt/lash --strip-components=1
  echo "EXTRACTED: $(ls /opt/lash/ 2>/dev/null)"
  echo "SOURCE_DIR: $(ls /opt/lash/source/ 2>/dev/null | head -5)"

  cd /opt/lash/source
  ./configure 2>&1 | tail -5
  SOLVER_CC="$(find /opt/lash -name 'Solver.cc' -type f 2>/dev/null | head -1)"
  if [ -n "$SOLVER_CC" ]; then
    sed -i 's/caml_process_pending_signals\b/caml_process_pending_signals_exn/g' "$SOLVER_CC"
    echo "PATCHED: $SOLVER_CC"
  fi
  make -j$(nproc) 2>&1 | tail -15

  candidate=$(find /opt/lash -maxdepth 4 -type f \( -name "lash" -o -name "lash.opt" -o -name "lash.byte" \) 2>/dev/null | head -1)
  if [ -n "$candidate" ]; then
    echo "BINARY_FOUND: $candidate"
  else
    echo "NO_BINARY"
    echo "BUILD_LOG: $(find /opt/lash -name "*.log" -o -name "*.status" 2>/dev/null | head -5)"
  fi
' 2>&1 | grep -E "(BINARY_FOUND|NO_BINARY|ocamlyacc|error|Error|FATAL)" || true

# ============================================================
# Summary
# ============================================================
echo ""
echo "=============================================="
echo " Tests complete."
echo " NOTE: apptainer exec env differs from apptainer build."
echo " For real validation, just run: apptainer build ..."
echo "=============================================="
