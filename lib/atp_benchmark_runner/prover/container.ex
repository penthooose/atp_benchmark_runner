defmodule AtpBenchmarkRunner.Prover.Container do
  @moduledoc """
  Containerization metadata for an ATP prover.

  The benchmark runner treats theorem provers as command-line tools. Elixir is
  used for orchestration, while reproducibility on HPC is achieved with
  Apptainer/Singularity images. Kubernetes can reuse the same OCI image metadata
  later, but FAU HPC execution should prefer `.sif` images.
  """

  @enforce_keys [:image_name, :def_path]
  defstruct [
    :image_name,
    :def_path,
    :docker_image,
    :homepage,
    :source_url,
    :license,
    backend: :apptainer,
    build_args: %{},
    notes: []
  ]

  @type t :: %__MODULE__{
          image_name: binary(),
          def_path: binary(),
          docker_image: binary() | nil,
          homepage: binary() | nil,
          source_url: binary() | nil,
          license: binary() | nil,
          backend: :apptainer | :docker | :kubernetes,
          build_args: map(),
          notes: [binary()]
        }

  @doc """
  Builds a container metadata struct.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      image_name: Map.fetch!(attrs, :image_name),
      def_path: Map.fetch!(attrs, :def_path),
      docker_image: Map.get(attrs, :docker_image),
      homepage: Map.get(attrs, :homepage),
      source_url: Map.get(attrs, :source_url),
      license: Map.get(attrs, :license),
      backend: Map.get(attrs, :backend, :apptainer),
      build_args: Map.get(attrs, :build_args, %{}),
      notes: Map.get(attrs, :notes, [])
    }
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = container) do
    %{
      image_name: container.image_name,
      def_path: container.def_path,
      docker_image: container.docker_image,
      homepage: container.homepage,
      source_url: container.source_url,
      license: container.license,
      backend: container.backend,
      build_args: container.build_args,
      notes: container.notes
    }
  end
end
