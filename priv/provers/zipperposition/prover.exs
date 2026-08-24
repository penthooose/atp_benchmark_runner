%{
  name: :zipperposition,
  label: "Zipperposition",
  aliases: ["zipperposition", "zipperpin", "zipper_position"],
  command_template:
    "apptainer exec {sif_path} /usr/local/bin/zipperposition --timeout {timeout_seconds} {problem}",
  container: %{
    def_path: "priv/provers/zipperposition/apptainer.def",
    docker_image: "docker.io/aise/atp-zipperposition:latest",
    dockerfile_path: "priv/provers/zipperposition/Containerfile"
  },
  metadata: %{logics: ["FOF", "CNF", "TFF", "lambda-free higher-order"]}
}
