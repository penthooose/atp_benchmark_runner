%{
  name: :leo2,
  label: "LEO-II",
  aliases: ["leo2", "leo_ii", "leoii"],
  # LEO-II delegates first-order sub-problems to an in-image E backend; the
  # absolute path is required because HOME is not visible inside the image.
  command_template:
    "apptainer exec {sif_path} leo --atp e=/usr/local/bin/eprover -po 1 -f e -at {timeout_seconds} -t {timeout_seconds} {problem}",
  container: %{
    def_path: "priv/provers/leo2/apptainer.def",
    docker_image: "docker.io/aise/atp-leo2:latest",
    dockerfile_path: "priv/provers/leo2/Containerfile"
  },
  metadata: %{logics: ["THF", "FOF", "CNF"]}
}
