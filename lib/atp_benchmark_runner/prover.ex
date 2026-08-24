defmodule AtpBenchmarkRunner.Prover do
  @moduledoc """
  Prover registry entries and command rendering.

  A prover describes how a single ATP executable or Apptainer image is invoked
  for one TPTP problem. Runtime orchestration lives elsewhere; this module only
  owns static prover metadata and command templates.
  """

  alias AtpBenchmarkRunner.HPC.Shell
  alias AtpBenchmarkRunner.Provers

  @enforce_keys [:name, :label, :command_template]
  defstruct [
    :name,
    :label,
    :sif_name,
    :sif_path,
    :command_template,
    parser: :szs,
    aliases: [],
    input: :tptp,
    supports: %{forms: :all, requires_conjecture?: false},
    default_args: [],
    env: %{},
    enabled?: true,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: atom(),
          label: binary(),
          sif_name: binary() | nil,
          sif_path: binary() | nil,
          command_template: binary(),
          parser: :szs | :smt_bare | atom() | tuple(),
          aliases: [binary()],
          input: :tptp | :smt2 | :thf | {:custom, module()} | atom(),
          supports: map(),
          default_args: keyword(),
          env: map(),
          enabled?: boolean(),
          metadata: map()
        }

  @doc """
  Returns all built-in prover descriptors.
  """
  @spec builtins() :: [t()]
  def builtins, do: AtpBenchmarkRunner.Provers.all()

  @doc """
  Fetches a built-in prover by atom or string name.
  """
  @spec builtin!(atom() | binary()) :: t()
  def builtin!(name), do: AtpBenchmarkRunner.Provers.fetch!(name)

  @doc """
  Fetches a built-in prover by atom or string name, returning `nil` when unknown.

  Use this on untrusted input (e.g. Livebook form data) to avoid leaking
  arbitrary atoms into the VM atom table.
  """
  @spec builtin(atom() | binary()) :: t() | nil
  def builtin(name) do
    case AtpBenchmarkRunner.Provers.fetch(name) do
      {:ok, prover} -> prover
      :error -> nil
    end
  end

  @doc """
  Converts atoms, maps, keyword lists, or structs into prover structs.
  """
  @spec normalize(t() | atom() | binary() | keyword() | map()) :: t()
  def normalize(%__MODULE__{} = prover), do: prover
  def normalize(name) when is_atom(name) or is_binary(name), do: builtin!(name)
  def normalize(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize()

  def normalize(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)

    %__MODULE__{
      name: normalize_name(Map.fetch!(attrs, :name)),
      label: Map.get(attrs, :label) || humanize_name(Map.fetch!(attrs, :name)),
      sif_name: Map.get(attrs, :sif_name),
      sif_path: Map.get(attrs, :sif_path),
      command_template: Map.fetch!(attrs, :command_template),
      parser: Map.get(attrs, :parser, :szs),
      aliases: Map.get(attrs, :aliases, []),
      input: Map.get(attrs, :input, :tptp),
      supports:
        Map.merge(%{forms: :all, requires_conjecture?: false}, Map.get(attrs, :supports, %{})),
      default_args: Map.get(attrs, :default_args, []),
      env: Map.get(attrs, :env, %{}),
      enabled?: Map.get(attrs, :enabled?, true),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Renders a prover command for local/preflight use where the problem path is
  already known at render time.
  """
  @spec render_command(t(), binary(), keyword()) :: binary()
  def render_command(%__MODULE__{} = prover, problem_path, opts \\ []) do
    replacements = %{
      "{problem}" => Shell.quote(problem_path),
      "{timeout_seconds}" => to_string(Keyword.get(opts, :timeout_seconds, 300)),
      "{timeout_ms}" => to_string(Keyword.get(opts, :timeout_seconds, 300) * 1_000),
      "{result_file}" => Shell.quote(Keyword.get(opts, :result_file, "result.out")),
      "{sif_path}" => Shell.quote(Keyword.get(opts, :sif_path) || prover.sif_path || ""),
      "{cores}" => "1"
    }

    replace_placeholders(prover.command_template, replacements)
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = prover) do
    %{
      name: prover.name,
      label: prover.label,
      sif_name: prover.sif_name,
      sif_path: prover.sif_path,
      command_template: prover.command_template,
      parser: prover.parser,
      aliases: prover.aliases,
      input: prover.input,
      supports: prover.supports,
      default_args: prover.default_args,
      env: prover.env,
      enabled?: prover.enabled?,
      metadata: prover.metadata
    }
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(map), do: normalize(map)

  defp replace_placeholders(template, replacements) do
    Enum.reduce(replacements, template, fn {placeholder, value}, acc ->
      String.replace(acc, placeholder, value)
    end)
  end

  defp normalize_name(name) when is_atom(name), do: name

  defp normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    case Provers.fetch(normalized) do
      {:ok, _prover} -> String.to_existing_atom(normalized)
      :error -> raise ArgumentError, "unknown prover #{inspect(name)}"
    end
  end

  defp humanize_name(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case known_key(key) do
          nil -> acc
          known -> Map.put(acc, known, value)
        end
    end)
  end

  defp known_key("enabled?"), do: :enabled?
  defp known_key("name"), do: :name
  defp known_key("label"), do: :label
  defp known_key("sif_name"), do: :sif_name
  defp known_key("sif_path"), do: :sif_path
  defp known_key("command_template"), do: :command_template
  defp known_key("parser"), do: :parser
  defp known_key("aliases"), do: :aliases
  defp known_key("input"), do: :input
  defp known_key("supports"), do: :supports
  defp known_key("default_args"), do: :default_args
  defp known_key("env"), do: :env
  defp known_key("metadata"), do: :metadata
  defp known_key(_unknown), do: nil
end
