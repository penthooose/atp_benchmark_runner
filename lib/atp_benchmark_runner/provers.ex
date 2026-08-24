defmodule AtpBenchmarkRunner.Provers do
  @moduledoc """
  Config-driven registry for supported theorem prover providers.

  Every prover is declared declaratively in `priv/provers/<name>/prover.exs`
  (next to its `Containerfile` and `apptainer.def`). The registry discovers
  provers by scanning that directory, so adding a prover is just dropping a
  new `priv/provers/<name>/` directory — no code changes or central lists.
  """

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.{Container, Spec}

  @doc """
  Returns all discovered prover descriptors.
  """
  @spec all() :: [Prover.t()]
  def all, do: Spec.load_all().provers

  @doc """
  Returns all prover names discovered from `priv/provers/*/prover.exs`.
  """
  @spec names() :: [atom()]
  def names, do: Spec.discover()

  @doc """
  Fetches a prover by canonical name or alias.
  """
  @spec fetch(atom() | binary()) :: {:ok, Prover.t()} | :error
  def fetch(name) do
    case canonical_name(name) do
      :unknown ->
        :error

      canonical ->
        case Enum.find(all(), &(&1.name == canonical)) do
          nil -> :error
          prover -> {:ok, prover}
        end
    end
  end

  @doc """
  Fetches a prover or raises.
  """
  @spec fetch!(atom() | binary()) :: Prover.t()
  def fetch!(name) do
    case fetch(name) do
      {:ok, prover} -> prover
      :error -> raise ArgumentError, "unknown prover #{inspect(name)}"
    end
  end

  @doc """
  Returns the output parser declared by a prover (`:szs` when unknown).
  """
  @spec parser_for(atom() | binary() | Prover.t()) :: atom() | tuple()
  def parser_for(%Prover{} = prover), do: prover.parser

  def parser_for(name) do
    case fetch(name) do
      {:ok, prover} -> prover.parser
      :error -> :szs
    end
  end

  @doc """
  Returns container metadata keyed by prover name.
  """
  @spec containers() :: %{optional(atom()) => Container.t()}
  def containers, do: Spec.load_all().containers

  @doc """
  Fetches container metadata by prover name or alias.
  """
  @spec container!(atom() | binary()) :: Container.t()
  def container!(name) do
    case Map.get(containers(), canonical_name(name)) do
      nil -> raise ArgumentError, "unknown prover container #{inspect(name)}"
      container -> container
    end
  end

  @doc """
  Summarises the integration research for all providers.
  """
  @spec research_summary() :: [map()]
  def research_summary do
    Enum.map(all(), fn prover ->
      container = Map.get(containers(), prover.name)

      %{
        name: prover.name,
        label: prover.label,
        integration: prover.metadata[:integration] || :cli,
        container_backend: container && container.backend,
        def_path: container && container.def_path,
        source_url: container && container.source_url,
        notes: (container && container.notes) || []
      }
    end)
  end

  @doc """
  Validates every discovered prover spec; returns a list of issue strings.
  Empty list means all specs are well-formed.
  """
  @spec validate() :: [binary()]
  def validate do
    Enum.flat_map(Spec.discover(), fn name ->
      case Spec.load(name) do
        {:ok, _prover, _container} -> []
        {:error, reason} -> ["#{name}: #{reason}"]
      end
    end)
  end

  @doc false
  @spec canonical_name(atom() | binary()) :: atom()
  def canonical_name(name) when is_atom(name), do: canonical_name(Atom.to_string(name))

  def canonical_name(name) when is_binary(name) do
    Map.get(name_index(), normalize(name), :unknown)
  end

  # Normalized binary (canonical name + declared aliases) => canonical atom.
  defp name_index do
    Enum.reduce(all(), %{}, fn prover, acc ->
      names = [Atom.to_string(prover.name) | prover.aliases || []]

      Enum.reduce(names, acc, fn name, inner ->
        Map.put(inner, normalize(name), prover.name)
      end)
    end)
  end

  defp normalize(name) when is_binary(name) do
    name |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end
end
