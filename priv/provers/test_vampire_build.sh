#!/bin/bash -l
# test_vampire_build.sh


set -Eeuo pipefail

PROXY="http://proxy.nhr.fau.de:80"
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export http_proxy="$PROXY"
export https_proxy="$PROXY"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,.nhr.fau.de"
export no_proxy="$NO_PROXY"

pass() { echo -e "  \e[32m✓ PASS\e[0m $1"; }
fail() { echo -e "  \e[31m✗ FAIL\e[0m $1"; }

echo "=============================================="
echo " Vampire Apptainer Build — Interactive Test"
echo "=============================================="
echo ""

# Step 1: Check Apptainer availability
echo "--- Step 1: Apptainer availability ---"
if command -v apptainer &>/dev/null; then
  pass "apptainer found: $(apptainer --version 2>&1 | head -1)"
else
  fail "apptainer not found — are you on a cluster node?"
  exit 1
fi
echo ""

# Step 2: Test pulling buildpack-deps:stable-curl (Debian/glibc + curl + ca-certs)
echo "--- Step 2: Pull buildpack-deps:stable-curl ---"
if apptainer exec docker://buildpack-deps:stable-curl sh -c 'echo ok' 2>/dev/null; then
  pass "buildpack-deps:stable-curl pulled and executed"
else
  fail "buildpack-deps:stable-curl pull failed"
fi
echo ""

# Step 3: Check available tools
echo "--- Step 3: Tools inside buildpack-deps:stable-curl ---"
TOOLS="curl wget find cp chmod ls mkdir"
for tool in $TOOLS; do
  if apptainer exec docker://buildpack-deps:stable-curl sh -c "which $tool" 2>/dev/null; then
    pass "$tool found"
  else
    fail "$tool NOT found"
  fi
done
# Also check for unzip and jq (should NOT be there)
for tool in unzip jq; do
  if apptainer exec docker://buildpack-deps:stable-curl sh -c "which $tool" 2>/dev/null; then
    fail "$tool unexpectedly found"
  else
    pass "$tool NOT found (expected — need to download)"
  fi
done
echo ""

# Step 4: Test curl with proxy → HTTPS
echo "--- Step 4: curl HTTPS through proxy (GitHub API) ---"
apptainer exec docker://buildpack-deps:stable-curl sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  curl -fsSL "https://api.github.com/repos/vprover/vampire/releases/latest" -o /tmp/vrel.json 2>&1
  echo "curl exit: $?"
  head -3 /tmp/vrel.json 2>/dev/null || echo "no output"
' 2>/dev/null
echo ""

# Step 5: Download jq static binary via curl
echo "--- Step 5: Download jq static binary ---"
apptainer exec docker://buildpack-deps:stable-curl sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux64" -o /tmp/jq 2>&1
  echo "jq download exit: $?"
  /tmp/jq --version 2>&1 || echo "jq not executable"
' 2>/dev/null
echo ""

# Step 6: Download static busybox (for unzip) via curl
echo "--- Step 6: Download static busybox ---"
apptainer exec docker://buildpack-deps:stable-curl sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -o /tmp/busybox 2>&1
  echo "busybox download exit: $?"
  chmod +x /tmp/busybox
  /tmp/busybox unzip --version 2>&1 | head -2
' 2>/dev/null
echo ""

# Step 7: Download and extract Vampire
echo "--- Step 7: Full Vampire download + extract + version check ---"
apptainer exec docker://buildpack-deps:stable-curl sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  cd /tmp

  # Get release URL
  curl -fsSL "https://api.github.com/repos/vprover/vampire/releases/latest" -o vrel.json
  url=$(jq -r ".assets[].browser_download_url" vrel.json | grep -Ei "Linux-X64" | grep -Evi "sha|sig|asc" | head -1)
  echo "Release URL: $url"

  # Download Vampire
  curl -fSL "$url" -o vampire.zip 2>&1
  echo "Vampire download exit: $?"
  ls -la vampire.zip

  # Download + use busybox for unzip
  curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -o /tmp/busybox
  chmod +x /tmp/busybox
  /tmp/busybox unzip -o vampire.zip -d vampire_extract

  # Find and test vampire binary
  found=$(find vampire_extract -type f -name vampire | head -1)
  echo "Found binary: $found"
  cp "$found" /usr/local/bin/vampire
  chmod +x /usr/local/bin/vampire
  /usr/local/bin/vampire --version
  echo "FULL PIPELINE EXIT: $?"
' 2>/dev/null
echo ""

echo "--- Step 8: Fallback — if buildpack-deps fails, test Alpine+apk with proxy ---"
apptainer exec docker://alpine:latest sh -c '
  export HTTP_PROXY="http://proxy.nhr.fau.de:80"
  export HTTPS_PROXY="http://proxy.nhr.fau.de:80"
  apk add --no-cache curl ca-certificates jq unzip 2>&1 | tail -3
  curl -fsSL "https://api.github.com/repos/vprover/vampire/releases/latest" -o /tmp/vrel.json 2>&1
  echo "Alpine+curl exit: $?"
  head -3 /tmp/vrel.json 2>/dev/null
' 2>/dev/null
echo ""

echo "=============================================="
echo " Tests complete. Share the output for analysis."
echo "=============================================="
