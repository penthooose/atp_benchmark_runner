defmodule AtpBenchmarkRunner.Prover.Spec do
  @moduledoc """
  Loads and validates declarative per-prover specs from `priv/provers/<name>/prover.exs`.

  A spec is deliberately minimal — only the keys the build and runtime actually
  use are allowed, and unknown keys are rejected on load:

    * identity — `name` (required), `label`, `aliases`
    * invocation — `command_template` (required), `sif_name` (defaults to `name`)
    * behavior hooks (all optional, only set when non-default) —
      `input` (`:tptp`/`:smt2`/`:thf`/`{:custom, Mod}`),
      `parser` (`:szs`/`:smt_bare`/`{:custom, Mod}`),
      `supports` (`%{forms:, requires_conjecture?:}` overlaid on defaults)
    * container — `container` (required): `def_path` (required for HPC),
      `docker_image` + `dockerfile_path` (local Docker); `image_name` defaults
      to the SIF name
    * free-form `metadata` — reserved for real consumers (e.g. `logics`, used
      by the HPC image smoke test to pick a compatible example)

  The registry (`Provers`) discovers provers purely by scanning this directory,
  so adding a prover is just dropping a `priv/provers/<name>/` directory that
  contains a `prover.exs` plus its `Containerfile` and `apptainer.def`.
  """

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @config_file "prover.exs"

  # Placeholders understood by `Prover.render_command/3` and the HPC job script.
  @known_placeholders ~w({problem} {timeout_seconds} {timeout_ms} {result_file} {sif_path} {cores})

  @required_top_level [:name, :command_template, :container]
  @known_top_level [
    :name,
    :label,
    :aliases,
    :sif_name,
    :command_template,
    :input,
    :parser,
    :local_execution,
    :our_prover,
    :supports,
    :container,
    :metadata
  ]
  @known_container [:image_name, :def_path, :docker_image, :dockerfile_path]

  @cache_key {__MODULE__, :loaded}

  @doc "Absolute path to the directory holding prover specs."
  @spec specs_dir() :: binary()
  def specs_dir do
    :code.priv_dir(:atp_benchmark_runner) |> Path.join("provers")
  end

  @doc "Absolute path to a prover's spec file, or `nil` when the dir is absent."
  @spec path(atom() | binary()) :: binary() | nil
  def path(name) do
    dir = Path.join(specs_dir(), to_string(name))
    if File.dir?(dir), do: Path.join(dir, @config_file), else: nil
  end

  @doc "Names of all configured provers (directories containing a `prover.exs`)."
  @spec discover() :: [atom()]
  def discover do
    specs_dir()
    |> File.ls!()
    |> Enum.filter(fn dir ->
      File.dir?(Path.join(specs_dir(), dir)) and
        File.regular?(Path.join([specs_dir(), dir, @config_file]))
    end)
    # Directory names are developer-controlled under priv/provers, so this is
    # the trusted registration point for canonical prover atoms.
    |> Enum.map(&String.to_atom/1)
    |> Enum.sort()
  end

  @doc """
  Loads and parses all discovered prover specs.

  The result is cached in `:persistent_term` and refreshed whenever the set of
  `prover.exs` files (or their modification times) changes, so config edits are
  picked up without a recompile while repeated access stays cheap.
  """
  @spec load_all() :: %{provers: [Prover.t()], containers: %{optional(atom()) => Container.t()}}
  def load_all do
    fingerprint = fingerprint()

    case :persistent_term.get(@cache_key, nil) do
      {^fingerprint, loaded} ->
        loaded

      _ ->
        loaded = do_load_all()
        :persistent_term.put(@cache_key, {fingerprint, loaded})
        loaded
    end
  end

  @doc """
  Loads one prover by name. Returns `{:ok, prover, container}` or `{:error, reason}`.
  """
  @spec load(atom() | binary()) :: {:ok, Prover.t(), Container.t()} | {:error, term()}
  def load(name) do
    case path(name) do
      nil ->
        {:error, "no spec directory for #{inspect(name)}"}

      file ->
        try do
          spec = eval_file!(file)
          validate!(spec, file)
          {:ok, to_prover(spec), to_container(spec)}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  @doc "Loads one prover or raises."
  @spec load!(atom() | binary()) :: {Prover.t(), Container.t()}
  def load!(name) do
    case load(name) do
      {:ok, prover, container} ->
        {prover, container}

      {:error, reason} ->
        raise ArgumentError, "invalid prover spec for #{inspect(name)}: #{reason}"
    end
  end

  @doc "Builds a `Prover` struct from a raw spec map."
  @spec to_prover(map()) :: Prover.t()
  def to_prover(spec) do
    spec
    |> Map.put_new(:sif_name, to_string(Map.fetch!(spec, :name)))
    |> Prover.normalize()
  end

  @doc "Builds a `Container` struct from the `:container` key of a spec map."
  @spec to_container(map()) :: Container.t()
  def to_container(spec) do
    sif_name = Map.get(spec, :sif_name, to_string(Map.fetch!(spec, :name)))

    spec
    |> Map.fetch!(:container)
    |> Map.put_new(:image_name, sif_name)
    |> Container.new()
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp do_load_all do
    {provers, containers} =
      discover()
      |> Enum.map(fn name ->
        {prover, container} = load!(name)
        {prover, {prover.name, container}}
      end)
      |> Enum.unzip()

    %{
      provers: provers,
      containers: Map.new(containers)
    }
  end

  defp fingerprint do
    specs_dir()
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn dir ->
      file = Path.join([specs_dir(), dir, @config_file])

      if File.regular?(file) do
        [{dir, File.stat!(file).mtime}]
      else
        []
      end
    end)
  end

  defp eval_file!(file) do
    {value, _binding} = Code.eval_file(file)

    case value do
      %{} = spec ->
        spec

      list when is_list(list) ->
        Map.new(list)

      other ->
        raise ArgumentError, "expected a map or keyword list, got #{inspect(other)}"
    end
  end

  defp validate!(spec, file) do
    Enum.each(@required_top_level, fn key ->
      unless Map.has_key?(spec, key) do
        raise ArgumentError, "missing required key `#{key}` in #{file}"
      end
    end)

    validate_unknown_keys!(spec, @known_top_level, file)

    spec
    |> Map.fetch!(:container)
    |> validate_unknown_keys!(@known_container, file <> " (container)")

    name = Map.fetch!(spec, :name)

    unless is_atom(name) do
      raise ArgumentError, "`name` must be an atom in #{file}, got #{inspect(name)}"
    end

    input = Map.get(spec, :input, :tptp)

    unless input in [:tptp, :smt2, :thf] or
             (is_tuple(input) and match?({:custom, mod} when is_atom(mod), input)) do
      raise ArgumentError, "unsupported `input` mode #{inspect(input)} in #{file}"
    end

    parser = Map.get(spec, :parser, :szs)

    unless parser in [:szs, :smt_bare] or
             (is_tuple(parser) and match?({:custom, mod} when is_atom(mod), parser)) do
      raise ArgumentError, "unsupported `parser` #{inspect(parser)} in #{file}"
    end

    local_execution = Map.get(spec, :local_execution, :container)

    unless local_execution in [:container, :escript] do
      raise ArgumentError,
            "unsupported `local_execution` #{inspect(local_execution)} in #{file}; " <>
              "expected :container or :escript"
    end

    our_prover = Map.get(spec, :our_prover, false)

    unless is_boolean(our_prover) do
      raise ArgumentError,
            "`our_prover` must be a boolean in #{file}, got #{inspect(our_prover)}"
    end

    validate_placeholders!(Map.fetch!(spec, :command_template), file)
    :ok
  end

  defp validate_unknown_keys!(map, allowed, file) do
    unknown = Map.keys(map) -- allowed

    if unknown != [] do
      raise ArgumentError,
            "unknown key(s) #{inspect(unknown)} in #{file}; allowed: #{Enum.join(allowed, ", ")}"
    end
  end

  defp validate_placeholders!(template, file) do
    unknown =
      template
      |> String.split(~r/\{[a-zA-Z_]+\}/, include_captures: true)
      |> Enum.filter(fn token ->
        String.starts_with?(token, "{") and token not in @known_placeholders
      end)

    if unknown != [] do
      raise ArgumentError,
            "unknown placeholder(s) #{inspect(unknown)} in command_template of #{file}; " <>
              "known: #{Enum.join(@known_placeholders, ", ")}"
    end
  end
end
