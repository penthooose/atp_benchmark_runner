%{
  name: :shot_tx,
  label: "Shot (HOL Tableaux)",
  aliases: ["shot", "shot-tx"],
  # Designated in-house prover: Report/Compare resolve "our prover" from this
  # flag via `Provers.our_prover/0` instead of a hardcoded prover name.
  our_prover: true,
  # Our own higher-order prover — ShotTx ("Shot"), the tableau component of the
  # Shot ecosystem (github.com/jcschuster/ShotTx, hex package `shot_tx`).
  #
  # ShotTx is THF/HOL-only: `input: :thf` routes FOF/CNF/TFF through the
  # TPTP.ToTHF converter (same as lash), since its parser cannot read FOF
  # directly ("Unexpected token: 'fof'"). It emits standard `% SZS status ...`
  # lines (`parser: :szs`), and the image entrypoint adds `--sat` for problems
  # without a conjecture so satisfiability checks are answered. Wall-clock
  # budget is set with its own `-t/--timeout` (milliseconds).
  command_template: "apptainer exec {sif_path} shot_tx --szs -t {timeout_ms} {problem}",
  input: :thf,
  container: %{
    def_path: "priv/provers/shot_tx/apptainer.def",
    docker_image: "docker.io/aise/atp-shot_tx:latest",
    dockerfile_path: "priv/provers/shot_tx/Containerfile"
  },

  # Shot is a HOL/THF tableau prover — the HPC image smoke test should pick a
  # THF example rather than a first-order one.
  metadata: %{logics: ["THF", "TH0", "TH1"]}
}
