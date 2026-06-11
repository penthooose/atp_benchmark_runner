# Vampire Docker image (downloads latest GitHub release binary).
#   docker build -t aise/atp-vampire:latest priv/provers/vampire/
#   docker run --rm aise/atp-vampire:latest --mode casc --time_limit 30 /problems/problem.p
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
    x86_64|amd64) suffix='Linux-X64.zip';; \
    aarch64|arm64) suffix='Linux-ARM64.zip';; \
    *) echo "Unsupported arch: $arch" >&2; exit 1;; \
    esac; \
    curl -fsSL https://api.github.com/repos/vprover/vampire/releases/latest -o /tmp/vampire_release.json; \
    url="$(grep -Eo 'https://[^\"]+'"$suffix" /tmp/vampire_release.json | head -1)"; \
    [ -n "$url" ] || { echo "Could not find asset for $suffix" >&2; exit 1; }; \
    curl -fL "$url" -o /tmp/vampire.zip; \
    unzip -o /tmp/vampire.zip -d /tmp/vampire_extracted; \
    found="$(find /tmp/vampire_extracted -type f | head -1)"; \
    [ -n "$found" ] || { echo "No files found in zip" >&2; exit 1; }; \
    cp "$found" /usr/local/bin/vampire; \
    chmod +x /usr/local/bin/vampire

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libomp5 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/vampire /usr/local/bin/vampire
ENTRYPOINT ["vampire"]
