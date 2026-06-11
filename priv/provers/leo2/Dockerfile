# LEO-II Docker image (legacy OCaml build).
#   docker build -t aise/atp-leo2:latest priv/provers/leo2/
#   docker run --rm aise/atp-leo2:latest --timeout 30 /problems/problem.p
FROM ubuntu:20.04 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential make ocaml ocaml-findlib camlp4 camlp5 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fL http://page.mi.fu-berlin.de/cbenzmueller/leo/leo2_v1.7.0.tgz -o /tmp/leo2.tgz && \
    mkdir -p /opt/leo2 && \
    tar -xzf /tmp/leo2.tgz -C /opt/leo2 --strip-components=1

WORKDIR /opt/leo2/src
RUN make 2>&1 || true

RUN printf '#!/bin/sh\necho "LEO-II binary not available (build fails on modern OCaml)." >&2\nexit 127\n' > /usr/local/bin/leo; \
    chmod +x /usr/local/bin/leo; \
    candidate="$(find /opt/leo2 -type f \( -name 'leo' -o -name 'leo.opt' -o -name 'leo.byte' \) | head -1)"; \
    if [ -n "$candidate" ]; then \
    cp "$candidate" /usr/local/bin/leo; \
    chmod +x /usr/local/bin/leo; \
    echo "LEO-II built from source: $candidate"; \
    else \
    echo "LEO-II source build failed, using stub binary"; \
    fi

FROM ubuntu:20.04
COPY --from=builder /usr/local/bin/leo /usr/local/bin/leo
ENTRYPOINT ["leo"]
