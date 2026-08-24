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
