defmodule AtpBenchmarkRunner.Provers.Zipperposition do
  @moduledoc """
  Provider for Zipperposition.

  The ticket sometimes says "Zipperpin"; this provider treats that as an alias
  for Zipperposition unless a separate prover is identified later.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :zipperposition,
      label: "Zipperposition",
      kind: :apptainer,
      sif_name: "zipperposition",
      executable: "zipperposition",
      command_template:
        "apptainer exec {sif_path} zipperposition --timeout {timeout_seconds} {problem}",
      metadata: %{
        aliases: [:zipperpin],
        logics: ["FOF", "CNF", "TFF", "lambda-free higher-order"],
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: true
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "zipperposition",
      def_path: "priv/provers/zipperposition/apptainer.def",
      docker_image: "aise/atp-zipperposition:latest",
      dockerfile_path: "priv/provers/zipperposition/Dockerfile",
      homepage: "https://github.com/sneeuwballen/zipperposition",
      source_url: "https://github.com/sneeuwballen/zipperposition",
      license: "BSD-2-Clause",
      notes: [
        "No Elixir binding found; upstream is OCaml/opam-based and provides a Dockerfile.",
        "Use --mode best by default; portfolio scripts can be exposed later for THF-heavy runs."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
