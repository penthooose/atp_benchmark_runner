%{
  name: :leo3,
  label: "Leo-III",
  aliases: ["leo3", "leo_iii", "leoiii"],
  command_template:
    "apptainer exec {sif_path} leo3 {problem} -t {timeout_seconds} -p --cores {cores}",
  container: %{
    def_path: "priv/provers/leo3/apptainer.def",
    docker_image: "docker.io/aise/atp-leo3:latest",
    dockerfile_path: "priv/provers/leo3/Containerfile"
  },
  metadata: %{logics: ["THF", "TFF", "FOF", "rank-1 polymorphic TPTP"]}
}
