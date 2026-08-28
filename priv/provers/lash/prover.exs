%{
  name: :lash,
  label: "Lash",
  # Lash is THF-only, so FOF/CNF/TFF is converted to Lash-safe TH0 first. As a
  # refutation prover it cannot report Satisfiable, so no-conjecture Satisfiable
  # problems are skipped (supports.requires_conjecture?).
  command_template:
    "apptainer exec {sif_path} lash -M /opt/lash/modes -t {timeout_seconds} {problem}",
  input: :thf,
  supports: %{requires_conjecture?: true},
  container: %{
    def_path: "priv/provers/lash/apptainer.def",
    docker_image: "docker.io/aise/atp-lash:latest",
    dockerfile_path: "priv/provers/lash/Containerfile"
  },
  metadata: %{logics: ["THF/TH0 (monomorphic) - FOF/CNF/TFF converted via TPTP.ToTHF"]}
}
