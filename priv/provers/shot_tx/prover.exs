%{
  name: :shot_tx,
  label: "Shot (HOL Tableaux)",
  aliases: ["shot", "shot-tx"],
  # Designated in-house prover: Report/Compare resolve "our prover" from this
  # flag via `Provers.our_prover/0` instead of a hardcoded prover name.
  our_prover: true,
  # In-house higher-order prover (ShotTx, github.com/jcschuster/ShotTx). THF/TH0/TH1
  # input passes through untouched and FOF/CNF/TFF is converted first; the
  # converter's Lash-specific output must never reach a TPTP-compliant prover.
  command_template: "apptainer exec {sif_path} shot_tx --szs -t {timeout_ms} {problem}",
  input: {:to_thf, :lash},
  accepts: ["THF", "TH0", "TH1"],
  converts: ["FOF", "CNF", "TFF"],
  container: %{
    def_path: "priv/provers/shot_tx/apptainer.def",
    docker_image: "docker.io/aise/atp-shot_tx:latest",
    dockerfile_path: "priv/provers/shot_tx/Containerfile"
  },

  # THF logic, so the HPC image smoke test picks a matching example.
  metadata: %{logics: ["THF", "TH0", "TH1"]}
}
