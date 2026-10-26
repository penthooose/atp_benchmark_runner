%{
  name: :cvc5,
  label: "CVC5",
  # cvc5 has no TPTP input dialect, so problems are converted to SMT-LIB first;
  # it then prints a bare sat/unsat/unknown answer (parser :smt_bare).
  # `converts` covers first-order input only: the encoding is one uninterpreted
  # sort with no types or higher-order constructs, so a TFF/THF problem would be
  # answered for something other than the problem. Those are reported as
  # InputError instead of producing a misleading verdict.
  command_template:
    "apptainer exec {sif_path} cvc5 --tlimit={timeout_ms} --finite-model-find {problem}",
  input: :smt2,
  converts: ["FOF", "CNF"],
  parser: :smt_bare,
  container: %{
    def_path: "priv/provers/cvc5/apptainer.def",
    docker_image: "docker.io/aise/atp-cvc5:latest",
    dockerfile_path: "priv/provers/cvc5/Containerfile"
  },
  metadata: %{logics: ["FOF/CNF/TFF/THF via TPTP→SMT-LIB conversion"]}
}
