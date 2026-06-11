# Zipperposition Docker image (OCaml/opam-based build).
#   docker build -t aise/atp-zipperposition:latest priv/provers/zipperposition/
#   docker run --rm aise/atp-zipperposition:latest --mode best --timeout 30 /problems/problem.p
FROM ocaml/opam:ubuntu-22.04-ocaml-4.14 AS builder
RUN sudo apt-get update && sudo apt-get install -y --no-install-recommends \
    ca-certificates git libgmp-dev m4 pkg-config python3 \
    && sudo rm -rf /var/lib/apt/lists/*
RUN opam update && opam install -y zipperposition
RUN sudo cp $(opam var bin)/zipperposition /usr/local/bin/zipperposition

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgmp-dev \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/zipperposition /usr/local/bin/zipperposition
ENTRYPOINT ["zipperposition"]
