defmodule AtpBenchmarkRunner.Prover.Container do
  @moduledoc """
  Container metadata for ATP provers.

  HPC runs use Apptainer `.sif` images. Same OCI metadata can be reused for K8s.
  """

  @enforce_keys [:image_name, :def_path]
  defstruct [
    :image_name,
    :def_path,
    :docker_image,
    :dockerfile_path,
    :source_url,
    backend: :apptainer,
    notes: []
  ]

  @type t :: %__MODULE__{
          image_name: binary(),
          def_path: binary(),
          docker_image: binary() | nil,
          dockerfile_path: binary() | nil,
          source_url: binary() | nil,
          backend: :apptainer | :docker | :kubernetes,
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
      dockerfile_path: Map.get(attrs, :dockerfile_path),
      source_url: Map.get(attrs, :source_url),
      backend: Map.get(attrs, :backend, :apptainer),
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
      dockerfile_path: container.dockerfile_path,
      source_url: container.source_url,
      backend: container.backend,
      notes: container.notes
    }
  end
end
