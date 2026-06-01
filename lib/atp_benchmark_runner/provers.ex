defmodule AtpBenchmarkRunner.Provers do
  @moduledoc """
  Registry for supported theorem prover providers.
  """

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @providers [
    AtpBenchmarkRunner.Provers.Tableaux,
    AtpBenchmarkRunner.Provers.Vampire,
    AtpBenchmarkRunner.Provers.EProver,
    AtpBenchmarkRunner.Provers.CVC5,
    AtpBenchmarkRunner.Provers.Zipperposition,
    AtpBenchmarkRunner.Provers.Leo3,
    AtpBenchmarkRunner.Provers.Leo2,
    AtpBenchmarkRunner.Provers.Lash
  ]

  @aliases %{
    zipperpin: :zipperposition,
    zipper_position: :zipperposition,
    e: :eprover,
    e_prover: :eprover,
    leo_iii: :leo3,
    leoiii: :leo3,
    leo_ii: :leo2,
    leoii: :leo2
  }

  @string_names %{
    "tableaux" => :tableaux,
    "simple_tableaux_solver" => :tableaux,
    "vampire" => :vampire,
    "e" => :eprover,
    "eprover" => :eprover,
    "e_prover" => :eprover,
    "cvc5" => :cvc5,
    "zipperpin" => :zipperposition,
    "zipperposition" => :zipperposition,
    "zipper_position" => :zipperposition,
    "leo3" => :leo3,
    "leo_iii" => :leo3,
    "leoiii" => :leo3,
    "leo2" => :leo2,
    "leo_ii" => :leo2,
    "leoii" => :leo2,
    "lash" => :lash
  }

  @doc """
  Returns all provider modules.
  """
  @spec providers() :: [module()]
  def providers, do: @providers

  @doc """
  Returns all built-in prover descriptors.
  """
  @spec all() :: [Prover.t()]
  def all, do: Enum.map(@providers, & &1.prover())

  @doc """
  Fetches a prover by canonical name or alias.
  """
  @spec fetch(atom() | binary()) :: {:ok, Prover.t()} | :error
  def fetch(name) do
    normalized = canonical_name(name)

    all()
    |> Enum.find(&(&1.name == normalized))
    |> case do
      nil -> :error
      prover -> {:ok, prover}
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
  Returns container metadata for all known providers.
  """
  @spec containers() :: [Container.t()]
  def containers, do: Enum.map(@providers, & &1.container())

  @doc """
  Fetches container metadata by prover name or alias.
  """
  @spec container!(atom() | binary()) :: Container.t()
  def container!(name) do
    canonical = canonical_name(name)

    @providers
    |> Enum.find(&(&1.prover().name == canonical))
    |> case do
      nil -> raise ArgumentError, "unknown prover container #{inspect(name)}"
      provider -> provider.container()
    end
  end

  @doc """
  Summarises the integration research for all providers.
  """
  @spec research_summary() :: [map()]
  def research_summary do
    Enum.map(@providers, fn provider ->
      prover = provider.prover()
      container = provider.container()

      %{
        name: prover.name,
        label: prover.label,
        integration: prover.metadata[:integration] || :cli,
        container_backend: container.backend,
        def_path: container.def_path,
        source_url: container.source_url,
        notes: provider.research_notes()
      }
    end)
  end

  @doc false
  @spec canonical_name(atom() | binary()) :: atom()
  def canonical_name(name) when is_atom(name), do: Map.get(@aliases, name, name)

  def canonical_name(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Map.get(@string_names, normalized, :unknown)
  end
end
