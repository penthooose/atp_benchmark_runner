defmodule AtpBenchmarkRunner.Provers.EProver do
  @moduledoc """
  Provider for the E theorem prover.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :eprover,
      label: "E-Prover",
      kind: :apptainer,
      sif_name: "eprover",
      executable: "eprover-ho",
      command_template:
        "apptainer exec {sif_path} eprover-ho --auto-schedule --proof-object --cpu-limit={timeout_seconds} {problem}",
      metadata: %{
        logics: ["FOF", "CNF", "TFF", "THF (monomorphic HO build)"],
        integration: :cli,
        provider: __MODULE__,
        k8s_candidate?: true
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "eprover",
      def_path: "priv/provers/eprover/apptainer.def",
      docker_image: "aise/atp-eprover:latest",
      homepage: "https://www.eprover.org/",
      source_url: "https://github.com/eprover/eprover",
      license: "GPL",
      notes: [
        "No mature Elixir binding found; use CLI execution.",
        "Build with ./configure --enable-ho to expose eprover-ho for higher-order benchmark subsets."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
