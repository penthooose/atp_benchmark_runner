defmodule AtpBenchmarkRunner.Provers.Lash do
  @moduledoc """
  Provider for Lash (TH0 higher-order prover).

  Lash is a THF-only higher-order prover: it rejects raw FOF/CNF/TFF input,
  so problems are converted to THF on the host side via `TPTP.ToTHF` before
  the file reaches the container.

  Lash is a TH0 prover (monomorphic higher-order logic with `$i` and `$o`), so
  FOF problems with function symbols, individual constants, and first-order
  quantification DO work after conversion (the `ToTHF` converter emits
  explicit `@`-application, correct `$i`/`$o` types, and parenthesized
  equations, which is what Lash needs).

  Lash is a refutation prover: it proves theorems but cannot report
  "Satisfiable" for non-theorems (that needs `-N`, which requires a
  `schedule_nontheorem` file that the image does not ship), so satisfiable
  problems time out and are reported as `UnsupportedLogic`.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :lash,
      label: "Lash",
      kind: :apptainer,
      sif_name: "lash",
      executable: "lash",
      command_template:
        "apptainer exec {sif_path} lash -M /opt/lash/modes -t {timeout_seconds} {problem}",
      metadata: %{
        supported_logics: [:thf, :th0],
        logics: ["THF/TH0 (monomorphic) - FOF/CNF/TFF converted via TPTP.ToTHF"],
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: false
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "lash",
      def_path: "priv/provers/lash/apptainer.def",
      docker_image: "docker.io/aise/atp-lash:latest",
      dockerfile_path: "priv/provers/lash/Containerfile",
      homepage: "http://grid01.ciirc.cvut.cz/~chad/lash/",
      source_url: "http://grid01.ciirc.cvut.cz/~chad/lash/",
      license: "unknown",
      notes: [
        "No Elixir binding found.",
        "THF/TH0 prover. FOF/CNF/TFF input is converted to THF on the host",
        "(explicit @-application, $i/$o types, parenthesized equations).",
        "Refutation prover: proves theorems; satisfiable problems time out",
        "(reported as UnsupportedLogic) because the image lacks the",
        "`schedule_nontheorem` file required by the `-N` flag."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
