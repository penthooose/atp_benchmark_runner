# Adding a Prover

Adding a theorem prover to `atp_benchmark_runner` is now **config-driven**: drop
a directory under `priv/provers/<name>/` and the registry picks it up
automatically.

A prover directory contains exactly three files:

| File            | Purpose                                                  |
| --------------- | -------------------------------------------------------- |
| `prover.exs`    | Declarative spec (identity, command, input/parser hooks) |
| `Containerfile` | OCI image for local Docker benchmarks                    |
| `apptainer.def` | Apptainer definition for HPC `.sif` builds               |

A ready-made scaffold lives in [`priv/provers/_template/`](../priv/provers/_template/).

## 0. Scope — which provers fit today

The plug-and-play path is designed for **TPTP-native provers**: they read `.p`
files directly and print a `% SZS status ...` line. That covers the large
majority of CASC/StarExec provers (Vampire, E, Leo-III, Zipperposition, Twee,
SPASS, GKC, Darwin, …) and needs **no extra configuration**.

The two special cases already in the repo show how _non_-TPTP-native input is
handled **in-repo** via Elixir hooks:

| Prover | `input` | `parser`    | Why                                             |
| ------ | ------- | ----------- | ----------------------------------------------- |
| cvc5   | `:smt2` | `:smt_bare` | cvc5 has no TPTP dialect; prints bare sat/unsat |
| lash   | `:thf`  | —           | lash accepts THF only                           |

**Recommendation:** for now, integrate TPTP-native provers. The extension path
for custom conversion/parsing by non-Elixir contributors is a roadmap item (see
[Custom input/parser for external provers](#7-custom-inputparser-for-external-provers)).

## 1. The spec (`prover.exs`)

Only the keys below are recognized; anything else is rejected on load, so a
spec cannot silently carry unused or misspelled fields.

| Key                         | Required | Meaning                                                                                                                       |
| --------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `name`                      | ✅       | Canonical atom used everywhere (`:vampire`)                                                                                   |
| `command_template`          | ✅       | Container invocation; placeholders `{problem}`, `{timeout_seconds}`, `{timeout_ms}`, `{sif_path}`, `{result_file}`, `{cores}` |
| `container.def_path`        | ✅       | Path to `apptainer.def` (HPC build)                                                                                           |
| `container.docker_image`    | ✅       | Docker image tag (local build/run)                                                                                            |
| `container.dockerfile_path` | ✅       | Path to `Containerfile` (local build)                                                                                         |
| `label`                     |          | Display name (GUI dropdown, reports); defaults to humanized `name`                                                            |
| `aliases`                   |          | Alternate lookup names, e.g. `["e", "e_prover"]` for eprover                                                                  |
| `sif_name`                  |          | SIF/image name when it differs from `name` (e.g. tableaux → `simple_tableaux_solver`)                                         |
| `input`                     |          | `:tptp` (default), `:smt2`, `:thf`, `{:custom, Mod}`                                                                          |
| `parser`                    |          | `:szs` (default), `:smt_bare`, `{:custom, Mod}`                                                                               |
| `supports`                  |          | `%{forms: [:fof, ...], requires_conjecture?: true}` overlaid on defaults                                                      |
| `metadata.logics`           |          | Used by the HPC image smoke test to pick a compatible example                                                                 |

`container.image_name` defaults to `sif_name`; `sif_name` defaults to `name` —
only override when they differ.

## 2. Reference example — Vampire

Vampire is the canonical minimal prover: TPTP-native, standard SZS output, and
the image just pulls an upstream release binary.

`priv/provers/vampire/prover.exs`:

```elixir
%{
  name: :vampire,
  label: "Vampire",
  command_template:
    "apptainer exec {sif_path} vampire --mode casc --cores {cores} --time_limit {timeout_seconds} {problem}",

  container: %{
    def_path: "priv/provers/vampire/apptainer.def",
    docker_image: "docker.io/aise/atp-vampire:latest",
    dockerfile_path: "priv/provers/vampire/Containerfile"
  },
  metadata: %{logics: ["FOF", "TFF", "THF", "SMT-LIB"]}
}
```

`priv/provers/vampire/Containerfile` (two-stage, copy a release binary):

```dockerfile
FROM docker.io/ubuntu:24.04 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    curl -fsSL https://api.github.com/repos/vprover/vampire/releases/latest -o /tmp/v.json; \
    url="$(grep -Eo 'https://[^"]+Linux-X64.zip' /tmp/v.json | head -1)"; \
    curl -fL "$url" -o /tmp/v.zip; unzip -o /tmp/v.zip -d /tmp/v; \
    cp "$(find /tmp/v -type f | head -1)" /usr/local/bin/vampire; chmod +x /usr/local/bin/vampire
FROM docker.io/ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libomp5 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/vampire /usr/local/bin/vampire
ENTRYPOINT ["vampire"]
```

`priv/provers/vampire/apptainer.def` mirrors the same steps, plus the FAU proxy
and a static `buildpack-deps` base (no package manager, to avoid rootless
build issues — see [Troubleshooting](#8-troubleshooting-fauapptainer)).

## 3. Step-by-step

1. **Pick a TPTP-native prover** and confirm it has a `--version`, reads `.p`
   files, and emits `% SZS status` / `# SZS status`.
2. **Copy the scaffold**: `cp -r priv/provers/_template priv/provers/<name>`
   and rename `prover.exs.template` → `prover.exs`.
3. **Fill in the spec** (`name`, `label`, `aliases`, `command_template`).
   Reference Vampire for the common case.
4. **Write `Containerfile` + `apptainer.def`** — prefer upstream release
   binaries; keep both files in sync (same source, same version).
5. **Validate the spec loads** (no unknown keys, valid placeholders):

   ```elixir
   AtpBenchmarkRunner.Provers.validate()
   # => []  (or a list of issues)
   AtpBenchmarkRunner.Prover.builtin!(:<name>)   # must not raise
   ```

6. **Local smoke**: build the Docker image and run it against a bundled
   example — either via the notebook (`examples/benchmark_local.livemd`,
   `auto_ensure_images: true`) or

   ```elixir
   AtpBenchmarkRunner.LocalRunner.ensure_docker_image!(:<name>)
   ```

7. **HPC smoke**: upload the `.def`, build the `.sif`, and validate it:

   ```elixir
   AtpBenchmarkRunner.upload_prover_definitions!(session, [Prover.builtin!(:<name>)])
   AtpBenchmarkRunner.build_prover_images!(session, [Prover.builtin!(:<name>)])
   AtpBenchmarkRunner.smoke_validate_images!(session, [Prover.builtin!(:<name>)])
   ```

8. **Commit** the directory; it is discovered automatically on the next
   compile / `Mix.install(force: true)`.

## 4. Behavior hooks (only when non-default)

### `input` — what the prover consumes

- `:tptp` (default) — raw `.p` file.
- `:smt2` — the runner converts TPTP → SMT-LIB first (cvc5).
- `:thf` — the runner converts FOF/CNF/TFF → Lash-safe TH0 first (lash).
- `{:custom, Mod}` — an Elixir module; **in-repo only** (see below).

### `parser` — how the output is read

- `:szs` (default) — standard `% SZS status` extraction.
- `:smt_bare` — bare `sat`/`unsat`/`unknown` mapped to SZS (cvc5).
- `{:custom, Mod}` — an Elixir module; **in-repo only**.

### `supports` — problem compatibility

- `%{forms: [:cnf, :fof, ...]}` filters problems by logic prefix.
- `%{requires_conjecture?: true}` skips no-conjecture Satisfiable problems
  (refutation provers such as lash). THF problems are always kept.
- Both are merged over `%{forms: :all, requires_conjecture?: false}`, so set
  only what differs.

## 5. Validation & tests

- `AtpBenchmarkRunner.Provers.validate/0` — loads every spec and returns issues
  (missing keys, unknown keys, bad placeholders, invalid `input`/`parser`).
- `mix test test/atp_benchmark_runner/prover_spec_test.exs` — registry,
  aliases, derived `sif_name`/`image_name`, input/parser/supports, and
  compatibility filtering.

## 6. What NOT to configure

The following fields were removed because nothing consumes them — do not add
them back (they are rejected on load): `kind`, `executable`, `homepage`,
`license`, `build_args`, `metadata.legacy?`, `metadata.k8s_candidate?`,
`metadata.native_apis`, `metadata.project`, `metadata.notes`,
`metadata.integration`.

## 7. Custom input/parser for external provers

You asked: _what about provers that need THF/SMT conversion or custom output
parsing — external contributors may not write Elixir?_

**Today** the only extension path for custom conversion is `{:custom, Mod}`,
which requires writing an Elixir module — effectively an in-repo change. That
is exactly why **the current scope is TPTP-native provers only**: they need no
conversion and standard SZS parsing, so external contributors need nothing but
a `prover.exs`, a `Containerfile`, and an `apptainer.def`.

**Recommended roadmap** (deferred — not needed for TPTP-native provers):

- **`input: {:script, "<cmd>"}`** — a shell/`python3`/`perl` command declared
  in `prover.exs` that converts a `.p` file. The runner would invoke it like
  `cmd <problem> <output_dir>` (local) / before sync (HPC) and use the file it
  writes. Contributors drop a `prepare.sh`/`convert.py` next to the config —
  no Elixir required. This mirrors how CASC/StarExec ship provers with their
  own scripts.
- **`parser: {:script, "<cmd>"}`** — a command that reads raw prover output on
  stdin and prints a normalized SZS status.

Both are natural extensions of the existing `Input` module and `Result` parser
dispatch; they just need a well-defined script contract and wiring into the
local + HPC runners. **Verdict: do not hard-limit to TPTP-native forever, but
defer the script hook** and let the easy provers (Vampire-class) carry the
integration for now.

## 8. Troubleshooting (FAU/Apptainer)

- **Rootless builds block `apt-get`** on FAU nodes (setgroups in the user
  namespace). Prefer static release binaries or source-compiled deps; the
  `buildpack-deps:stable-curl` base avoids package managers entirely.
- **Proxy**: set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` to
  `proxy.nhr.fau.de:80` in `%post` (already in the template).
- **OCaml-built provers** (zipperposition, leo2): the opam switch lives under
  `/home/opam`, but FAU bind-mounts the host `/home` into containers, hiding it.
  Move the switch to `/opt/opam` and set `CAML_LD_LIBRARY_PATH` for the OCaml
  `dll*.so` stublibs (dlopened at runtime, invisible to `ldd`).
- **HPC SIF path**: the runner derives
  `${HPC_WORK_DIR}/singularity_images/<sif_name>.sif` from `sif_name`; keep
  `sif_name` in sync with the built `.sif`.
- **Validate with a hard problem**, not a trivial one — a prover can "solve"
  easy theorems with its own calculus while its backend (e.g. leo2 → E) is
  actually broken.
