defmodule AtpBenchmarkRunner.Provers.Vampire do
  @moduledoc """
  Provider for the Vampire theorem prover.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :vampire,
      label: "Vampire",
      kind: :apptainer,
      sif_name: "vampire",
      executable: "vampire",
      command_template:
        "apptainer exec {sif_path} vampire --mode casc --cores {cores} --time_limit {timeout_seconds} {problem}",
      metadata: %{
        logics: ["FOF", "TFF", "THF", "SMT-LIB"],
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: true
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "vampire",
      def_path: "priv/provers/vampire/apptainer.def",
      docker_image: "docker.io/aise/atp-vampire:latest",
      dockerfile_path: "priv/provers/vampire/Containerfile",
      homepage: "https://vprover.github.io/",
      source_url: "https://github.com/vprover/vampire",
      license: "BSD-3-Clause",
      notes: [
        "No mature Elixir binding found; use the official CLI from an Apptainer image.",
        "Vampire provides release binaries and a Dockerfile upstream; portfolio mode is recommended for TPTP benchmarking."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
