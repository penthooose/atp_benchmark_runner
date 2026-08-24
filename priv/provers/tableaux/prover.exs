%{
  name: :tableaux,
  label: "AISE Tableaux Prover",
  aliases: ["tableaux", "simple_tableaux_solver"],
  sif_name: "simple_tableaux_solver",
  # `--no-llm` is REQUIRED: the item #12 solver defaults `llm` to true and
  # would otherwise call OpenRouter during benchmarks.
  command_template:
    "apptainer exec {sif_path} simple_tableaux_solver --no-llm --tptp-file {problem}",
  container: %{
    def_path: "priv/provers/tableaux/apptainer.def",
    docker_image: "docker.io/aise/simple-tableaux-solver:latest",
    dockerfile_path: "priv/provers/tableaux/Containerfile"
  }
}
