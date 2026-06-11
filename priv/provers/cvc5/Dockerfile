# CVC5 Docker image (downloads latest GitHub release binary).
#   docker build -t aise/atp-cvc5:latest priv/provers/cvc5/
#   docker run --rm aise/atp-cvc5:latest --lang=tptp --tlimit=30000 /problems/problem.p
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
    x86_64|amd64) suffix='Linux-x86_64-static.zip';; \
    aarch64|arm64) suffix='Linux-arm64-static.zip';; \
    *) echo "Unsupported arch: $arch" >&2; exit 1;; \
    esac; \
    curl -fsSL https://api.github.com/repos/cvc5/cvc5/releases/latest -o /tmp/cvc5_release.json; \
    url="$(grep -Eo 'https://[^\"]+'"$suffix" /tmp/cvc5_release.json | head -1)"; \
    [ -n "$url" ] || { echo "Could not find asset for $suffix" >&2; exit 1; }; \
    curl -fL "$url" -o /tmp/cvc5.zip; \
    mkdir -p /tmp/cvc5_unpack; \
    unzip /tmp/cvc5.zip -d /tmp/cvc5_unpack; \
    found="$(find /tmp/cvc5_unpack -type f -name cvc5 | head -1)"; \
    [ -n "$found" ] || { echo "cvc5 binary not found in archive" >&2; exit 1; }; \
    install -m 0755 "$found" /usr/local/bin/cvc5

FROM ubuntu:24.04
COPY --from=builder /usr/local/bin/cvc5 /usr/local/bin/cvc5
ENTRYPOINT ["cvc5"]
