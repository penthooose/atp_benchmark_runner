defmodule AtpBenchmarkRunner.Provers.Leo3 do
  @moduledoc """
  Provider for Leo-III.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :leo3,
      label: "Leo-III",
      kind: :apptainer,
      sif_name: "leo3",
      executable: "leo3",
      command_template: "apptainer exec {sif_path} leo3 {problem} -t {timeout_seconds} -p",
      metadata: %{
        aliases: [:leo_iii],
        logics: ["THF", "TFF", "FOF", "rank-1 polymorphic TPTP"],
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: true
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "leo3",
      def_path: "priv/provers/leo3/apptainer.def",
      docker_image: "aise/atp-leo3:latest",
      dockerfile_path: "priv/provers/leo3/Dockerfile",
      homepage: "https://github.com/leoprover/Leo-III",
      source_url: "https://github.com/leoprover/Leo-III",
      license: "BSD-3-Clause",
      notes: [
        "No Elixir binding found; Leo-III is Scala/JVM-based and supports common TPTP dialects.",
        "A release jar or sbt-built assembly is the most practical Apptainer runtime."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
