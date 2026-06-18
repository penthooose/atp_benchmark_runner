defmodule AtpBenchmarkRunner.Provers.CVC5 do
  @moduledoc """
  Provider for cvc5.
  """

  @behaviour AtpBenchmarkRunner.Provers.Provider

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @impl true
  def prover do
    Prover.normalize(%{
      name: :cvc5,
      label: "CVC5",
      kind: :apptainer,
      sif_name: "cvc5",
      executable: "cvc5",
      command_template: "apptainer exec {sif_path} cvc5 --tlimit={timeout_ms} {problem}",
      metadata: %{
        logics: ["SMT-LIB", "TPTP where supported by cvc5 parser"],
        integration: :cli,
        provider: __MODULE__,
        native_apis: ["C++", "Python", "Java", "Rust community binding"],
        k8s_candidate?: true
      }
    })
  end

  @impl true
  def container do
    Container.new(%{
      image_name: "cvc5",
      def_path: "priv/provers/cvc5/apptainer.def",
      docker_image: "docker.io/aise/atp-cvc5:latest",
      dockerfile_path: "priv/provers/cvc5/Containerfile",
      homepage: "https://cvc5.github.io/",
      source_url: "https://github.com/cvc5/cvc5",
      license: "BSD-3-Clause style",
      notes: [
        "No Elixir binding found; cvc5 has official non-Elixir APIs and a stable standalone CLI.",
        "Use CLI mode for benchmark parity; direct NIF/Port binding can be evaluated later only if tight SMT API integration is needed."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
