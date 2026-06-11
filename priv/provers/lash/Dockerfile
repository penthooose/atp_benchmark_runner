# Lash Docker image (experimental, OCaml-based).
#   docker build -t aise/atp-lash:latest priv/provers/lash/
#   docker run --rm aise/atp-lash:latest /problems/problem.p
ARG LASH_URL=http://grid01.ciirc.cvut.cz/~chad/lash/lash-1.14.tar.gz

FROM ubuntu:24.04 AS builder
ARG LASH_URL
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential make ocaml \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/lash && \
    curl -fL "${LASH_URL}" -o /tmp/lash.tar.gz && \
    tar -xzf /tmp/lash.tar.gz -C /opt/lash --strip-components=1 || true

WORKDIR /opt/lash
RUN if [ -f Makefile ] || [ -f makefile ]; then make || true; \
    elif [ -f configure ]; then ./configure && make || true; fi

RUN candidate="$(find /opt/lash -maxdepth 3 -type f \( -name 'lash' -o -name 'lash.opt' -o -name 'lash.byte' \) | head -1)" && \
    if [ -n "$candidate" ]; then cp "$candidate" /usr/local/bin/lash; fi

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ocaml-runtime \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/lash /usr/local/bin/lash
RUN if [ ! -x /usr/local/bin/lash ]; then \
    printf '#!/bin/sh\necho "Lash binary not built. Pin LASH_URL build-arg." >&2\nexit 127\n' > /usr/local/bin/lash; \
    chmod +x /usr/local/bin/lash; \
    fi
ENTRYPOINT ["lash"]
