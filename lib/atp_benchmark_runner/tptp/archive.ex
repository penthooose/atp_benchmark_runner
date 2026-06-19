defmodule AtpBenchmarkRunner.TPTP.Archive do
  @moduledoc """
  Official TPTP archive metadata.

  The upstream project currently publishes one full `.tgz` distribution rather
  than small per-logic zip files. The runner therefore exposes component and
  problem filters after extraction instead of pretending partial official
  archives exist.
  """

  @enforce_keys [:id, :label, :version, :url, :archive_name]
  defstruct [
    :id,
    :label,
    :version,
    :url,
    :archive_name,
    :size,
    :expands_to,
    :description,
    default?: false,
    components: []
  ]

  @type t :: %__MODULE__{
          id: atom(),
          label: binary(),
          version: binary(),
          url: binary(),
          archive_name: binary(),
          size: binary() | nil,
          expands_to: binary() | nil,
          description: binary() | nil,
          default?: boolean(),
          components: [atom()]
        }

  @current_version "9.2.1"
  @base_url "https://tptp.org/TPTP"

  @doc """
  Returns selectable official TPTP archive distributions.
  """
  @spec available() :: [t()]
  def available, do: [full()]

  @doc """
  Returns the current official full TPTP archive.
  """
  @spec full() :: t()
  def full do
    archive_name = "TPTP-v#{@current_version}.tgz"

    %__MODULE__{
      id: :tptp_full,
      label: "TPTP v#{@current_version} full library",
      version: @current_version,
      url: "#{@base_url}/Distribution/#{archive_name}",
      archive_name: archive_name,
      size: "881MB",
      expands_to: "9.9GB",
      default?: true,
      components: [:problems, :axioms, :generators, :documents, :utilities],
      description:
        "Official full TPTP distribution containing Problems/, Axioms/, documents, and utilities."
    }
  end

  @doc false
  @spec normalize(t() | atom() | binary()) :: t()
  def normalize(%__MODULE__{} = archive), do: archive
  def normalize(:full), do: full()
  def normalize(:tptp_full), do: full()
  def normalize("full"), do: full()
  def normalize("tptp_full"), do: full()

  def normalize(value) do
    raise ArgumentError, "unknown TPTP archive #{inspect(value)}"
  end
end
