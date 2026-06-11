# LEO-II Docker image (legacy OCaml build).
#   docker build -t aise/atp-leo2:latest priv/provers/leo2/
#   docker run --rm aise/atp-leo2:latest --timeout 30 /problems/problem.p
FROM ubuntu:20.04 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential make ocaml ocaml-findlib camlp5 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fL http://page.mi.fu-berlin.de/cbenzmueller/leo/leo2_v1.7.0.tgz -o /tmp/leo2.tgz && \
    mkdir -p /opt/leo2 && \
    tar -xzf /tmp/leo2.tgz -C /opt/leo2 --strip-components=1

WORKDIR /opt/leo2
RUN make || true
RUN candidate="$(find /opt/leo2 -type f \( -name 'leo' -o -name 'leo.opt' -o -name 'leo.byte' \) | head -1)" && \
    if [ -z "$candidate" ]; then echo "LEO-II build failed" >&2; exit 1; fi && \
    cp "$candidate" /usr/local/bin/leo

FROM ubuntu:20.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ocaml-runtime \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/leo /usr/local/bin/leo
ENTRYPOINT ["leo"]
