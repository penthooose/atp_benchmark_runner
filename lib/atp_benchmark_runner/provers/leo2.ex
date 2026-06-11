defmodule AtpBenchmarkRunner.Provers.Leo2 do
  @moduledoc """
  Provider for LEO-II.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :leo2,
      label: "LEO-II",
      kind: :apptainer,
      sif_name: "leo2",
      executable: "leo",
      command_template: "apptainer exec {sif_path} leo --timeout {timeout_seconds} {problem}",
      metadata: %{
        aliases: [:leo_ii],
        logics: ["THF", "FOF", "CNF"],
        integration: :cli,
        provider: __MODULE__,
        legacy?: true,
        k8s_candidate?: false
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "leo2",
      def_path: "priv/provers/leo2/apptainer.def",
      docker_image: "aise/atp-leo2:latest",
      dockerfile_path: "priv/provers/leo2/Dockerfile",
      homepage: "http://page.mi.fu-berlin.de/cbenzmueller/leo/",
      source_url: "http://page.mi.fu-berlin.de/cbenzmueller/leo/download.html",
      license: "BSD",
      notes: [
        "No Elixir binding found; LEO-II is a legacy OCaml prover and should be containerized for reproducibility.",
        "Prefer Leo-III for active development, but keep LEO-II available for historical THF comparisons."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
