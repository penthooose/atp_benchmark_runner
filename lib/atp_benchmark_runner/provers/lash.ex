defmodule AtpBenchmarkRunner.Provers.Lash do
  @moduledoc """
  Provider for Lash (THF higher-order prover).

  Lash is a THF-only higher-order prover. FOF/CNF/TFF problems are converted
  to THF on the host side via `TPTP.ToTHF` before the file reaches the
  container.

  **Important:** Lash only supports problems at the `$o` (boolean) level.
  It cannot handle `$i` (individual) types — FOF problems with function
  symbols, individual constants, or first-order quantification over
  individuals will fail with an `UnsupportedLogic` result.
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
        logics: ["THF only — FOF/CNF/TFF problems with $i types are unsupported"],
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
        "THF-only prover. FOF/CNF/TFF problems with $i types will be",
        "skipped (UnsupportedLogic). Only problems at the $o boolean",
        "level are supported.",
        "FOF problems without function symbols (pure propositional)",
        "work — they convert to $o-level THF."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
