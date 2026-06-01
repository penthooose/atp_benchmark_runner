defmodule AtpBenchmarkRunner.Provers.Tableaux do
  @moduledoc """
  Provider for the AISE simple tableaux prover from item #12.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :tableaux,
      label: "AISE Tableaux Prover",
      kind: :apptainer,
      sif_name: "simple_tableaux_solver",
      executable: "simple_tableaux_solver",
      command_template:
        "apptainer exec {sif_path} simple_tableaux_solver solve {problem} --timeout {timeout_seconds}",
      metadata: %{
        project: "item #12",
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: true,
        notes: "Replace command once the final CLI is fixed."
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "simple_tableaux_solver",
      def_path: "priv/provers/tableaux/apptainer.def",
      docker_image: "aise/simple-tableaux-solver:latest",
      homepage:
        "../item_12_Integrating_external_solvers_into_Elixir_and_Livebook/simple_tableaux_solver",
      source_url:
        "../item_12_Integrating_external_solvers_into_Elixir_and_Livebook/simple_tableaux_solver",
      license: "project-local",
      notes: [
        "Project-local Elixir prover; container should package the Mix release/escript once the CLI stabilizes.",
        "Keep this provider as the benchmark reference for our own solver."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
