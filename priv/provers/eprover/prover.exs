%{
  name: :eprover,
  label: "E-Prover",
  aliases: ["eprover", "e", "e_prover"],
  command_template:
    "apptainer exec {sif_path} eprover-ho --auto-schedule --proof-object --cpu-limit={timeout_seconds} {problem}",
  container: %{
    def_path: "priv/provers/eprover/apptainer.def",
    docker_image: "docker.io/aise/atp-eprover:latest",
    dockerfile_path: "priv/provers/eprover/Containerfile"
  },
  metadata: %{logics: ["FOF", "CNF", "TFF", "THF (monomorphic HO build)"]}
}
