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
      # The solver's escript CLI (item #12, STS.HybridTableauxSolverMain) takes
      # `--tptp-file <path>` — there is no `solve` subcommand nor `--timeout`
      # flag. The wall-time bound is applied by the runner's `timeout` wrapper,
      # so no per-prover timeout flag is needed here.
      command_template: "apptainer exec {sif_path} simple_tableaux_solver --tptp-file {problem}",
      metadata: %{
        project: "item #12",
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: true,
        notes:
          "CLI: `--tptp-file <path>` (symbolic/hybrid route decided by the solver heuristic)."
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "simple_tableaux_solver",
      def_path: "priv/provers/tableaux/apptainer.def",
      docker_image: "docker.io/aise/simple-tableaux-solver:latest",
      dockerfile_path: "priv/provers/tableaux/Containerfile",
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
