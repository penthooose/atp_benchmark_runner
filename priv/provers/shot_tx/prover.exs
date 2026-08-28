%{
  name: :shot_tx,
  label: "Shot (HOL Tableaux)",
  aliases: ["shot", "shot-tx"],
  # Designated in-house prover: Report/Compare resolve "our prover" from this
  # flag via `Provers.our_prover/0` instead of a hardcoded prover name.
  our_prover: true,
  # In-house higher-order prover (ShotTx, github.com/jcschuster/ShotTx). It is
  # THF-only, so `input: :thf` routes FOF/CNF/TFF through the TPTP.ToTHF
  # converter (as for lash), and the image entrypoint adds `--sat` for problems
  # without a conjecture.
  command_template: "apptainer exec {sif_path} shot_tx --szs -t {timeout_ms} {problem}",
  input: :thf,
  container: %{
    def_path: "priv/provers/shot_tx/apptainer.def",
    docker_image: "docker.io/aise/atp-shot_tx:latest",
    dockerfile_path: "priv/provers/shot_tx/Containerfile"
  },

  # THF logic, so the HPC image smoke test picks a matching example.
  metadata: %{logics: ["THF", "TH0", "TH1"]}
}
