defmodule AtpBenchmarkRunner.Provers.Lash do
  @moduledoc """
  Provider placeholder for Lash.
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
        logics: ["THF (typed higher-order only)"],
        supported_logics: [:thf, :th0],
        integration: :cli,
        provider: __MODULE__,
        experimental?: true,
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
        "Container definition is intentionally a placeholder until a stable source/binary URL is confirmed."
      ]
    })
  end

  @impl true
  def research_notes, do: container().notes
end
