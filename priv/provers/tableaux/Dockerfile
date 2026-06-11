# AISE Tableaux Solver Docker image (Elixir escript build).
#   docker build -t aise/simple-tableaux-solver:latest priv/provers/tableaux/
#   docker run --rm aise/simple-tableaux-solver:latest solve /problems/problem.p --timeout 30
FROM hexpm/elixir:1.17.3-erlang-27.1-debian-bookworm-20240904-slim AS builder

ARG TABLEAUX_REPO=https://github.com/ase-build/simple_tableaux_solver.git
ARG TABLEAUX_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

RUN git clone --depth 1 --branch "${TABLEAUX_REF}" "${TABLEAUX_REPO}" /opt/simple_tableaux_solver
WORKDIR /opt/simple_tableaux_solver
RUN mix deps.get && MIX_ENV=prod mix escript.build && \
    install -m 0755 simple_tableaux_solver /usr/local/bin/simple_tableaux_solver

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/simple_tableaux_solver /usr/local/bin/simple_tableaux_solver
ENTRYPOINT ["simple_tableaux_solver"]
