defmodule AtpBenchmarkRunner.HPC.Images do
  @moduledoc """
  Apptainer image management for prover providers.

  This module is the bridge between prover metadata and `hpc_connect`'s existing
  SIF build/upload support. It keeps image preparation explicit so benchmark
  submission can remain fast and predictable.
  """

  alias AtpBenchmarkRunner.{Prover, Provers}
  alias AtpBenchmarkRunner.Prover.Container

  @doc """
  Returns the absolute local Apptainer definition path for a prover/container.
  """
  @spec local_def_path(Prover.t() | Container.t() | atom() | binary()) :: binary()
  def local_def_path(%Prover{name: name}), do: name |> Provers.container!() |> local_def_path()

  def local_def_path(name) when is_atom(name) or is_binary(name),
    do: name |> Provers.container!() |> local_def_path()

  def local_def_path(%Container{def_path: def_path}) do
    app_root = :code.priv_dir(:atp_benchmark_runner) |> to_string() |> Path.dirname()
    Path.expand(def_path, app_root)
  end

  @doc """
  Returns a remote SIF path for a prover using the `hpc_connect` convention.
  """
  @spec remote_sif_path(HpcConnect.Session.t(), Prover.t() | atom() | binary()) :: binary()
  def remote_sif_path(%HpcConnect.Session{} = session, %Prover{sif_name: name}) do
    HpcConnect.remote_sif_path(session, name)
  end

  def remote_sif_path(%HpcConnect.Session{} = session, name)
      when is_atom(name) or is_binary(name) do
    remote_sif_path(session, Provers.fetch!(name))
  end

  @doc """
  Returns a remote definition-file path using the `hpc_connect` convention.
  """
  @spec remote_def_path(HpcConnect.Session.t(), Prover.t() | atom() | binary()) :: binary()
  def remote_def_path(%HpcConnect.Session{} = session, %Prover{} = prover) do
    HpcConnect.remote_def_path(session, remote_image_name(prover))
  end

  def remote_def_path(%HpcConnect.Session{} = session, name)
      when is_atom(name) or is_binary(name) do
    remote_def_path(session, Provers.fetch!(name))
  end

  @doc """
  Returns the strategy used to connect ATP-specific defs with `hpc_connect`.

  We deliberately do **not** copy ATP definitions into the dependency's `priv/`
  directory. Mix dependencies are implementation artifacts and may be fetched,
  compiled, or replaced. `hpc_connect` already exposes a public
  `upload_def_file/3` API that accepts arbitrary local definition paths, so this
  library keeps ownership of prover definitions and delegates transport/building.
  """
  @spec integration_strategy() :: map()
  def integration_strategy do
    %{
      owner: :atp_benchmark_runner,
      local_def_dir: "priv/provers/<prover>/apptainer.def",
      remote_def_dir: "<hpc_connect work_dir>/singularity_def_files",
      remote_image_dir: "<hpc_connect work_dir>/singularity_images",
      build_script_owner: :hpc_connect,
      build_script: "priv/scripts/build_sif.sh",
      transport: "HpcConnect.upload_def_file(session, name, local_def_path)",
      build: "HpcConnect.build_sif(session, name: name, local_def_path: local_def_path)"
    }
  end

  @doc """
  Returns a session-aware image build plan for Livebook and dry runs.
  """
  @spec build_plan(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def build_plan(%HpcConnect.Session{} = session, provers, opts \\ []) when is_list(provers) do
    %{
      strategy: integration_strategy(),
      install_hpc_connect_scripts?: Keyword.get(opts, :install_scripts, true),
      build_cluster: Keyword.get(opts, :build_cluster, :hpc_connect_default_fallbacks),
      use_slurm: Keyword.get(opts, :use_slurm, false),
      entries: Enum.map(provers, &build_plan_entry(session, &1, opts))
    }
  end

  @doc """
  Installs `hpc_connect`'s generic remote build scripts.

  The build script remains in `hpc_connect` because it is generic infrastructure;
  ATP-specific `.def` files remain in this package and are uploaded separately.
  """
  @spec install_build_tools!(HpcConnect.Session.t(), keyword()) :: :ok
  def install_build_tools!(%HpcConnect.Session{} = session, opts \\ []) do
    HpcConnect.install_remote_scripts!(session,
      reset_permission: Keyword.get(opts, :reset_permission, false)
    )
  end

  @doc """
  Uploads one ATP prover definition to `<work_dir>/singularity_def_files/<name>.def`.
  """
  @spec upload_definition!(HpcConnect.Session.t(), Prover.t() | atom() | binary(), keyword()) ::
          binary()
  def upload_definition!(%HpcConnect.Session{} = session, prover_or_name, opts \\ []) do
    prover = normalize_prover(prover_or_name)
    maybe_install_build_tools!(session, opts)

    HpcConnect.upload_def_file(session, remote_image_name(prover), local_def_path(prover))
  end

  @doc """
  Uploads all selected ATP prover definitions and returns remote paths by prover.
  """
  @spec upload_definitions!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def upload_definitions!(%HpcConnect.Session{} = session, provers, opts \\ [])
      when is_list(provers) do
    maybe_install_build_tools!(session, opts)

    Map.new(provers, fn prover ->
      {prover.name,
       HpcConnect.upload_def_file(session, remote_image_name(prover), local_def_path(prover))}
    end)
  end

  @doc """
  Submits or launches a non-blocking SIF build through `hpc_connect`.
  """
  @spec build_job!(HpcConnect.Session.t(), Prover.t() | atom() | binary(), keyword()) :: map()
  def build_job!(%HpcConnect.Session{} = session, prover_or_name, opts \\ []) do
    prover = normalize_prover(prover_or_name)
    maybe_install_build_tools!(session, opts)

    HpcConnect.build_sif_job(session, build_opts(prover, opts))
  end

  @doc """
  Builds one prover SIF on the remote HPC environment via `hpc_connect`.

  This uses the local Apptainer definition bundled under `priv/provers/<name>/`.
  """
  @spec build!(HpcConnect.Session.t(), Prover.t() | atom() | binary(), keyword()) :: binary()
  def build!(%HpcConnect.Session{} = session, prover_or_name, opts \\ []) do
    prover = normalize_prover(prover_or_name)
    maybe_install_build_tools!(session, opts)

    HpcConnect.build_sif(session, build_opts(prover, opts))
  end

  @doc """
  Ensures all prover images for a run are available.

  By default this only returns the expected remote paths. Pass `build: true` to
  call `HpcConnect.build_sif/3` for each image.
  """
  @spec ensure_for_run!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def ensure_for_run!(%HpcConnect.Session{} = session, provers, opts \\ [])
      when is_list(provers) do
    if Keyword.get(opts, :build, false) do
      build_all!(session, provers, opts)
    else
      Map.new(provers, fn prover -> {prover.name, remote_sif_path(session, prover)} end)
    end
  end

  @doc """
  Builds all selected prover images and returns remote SIF paths by prover.
  """
  @spec build_all!(HpcConnect.Session.t(), [Prover.t()], keyword()) :: map()
  def build_all!(%HpcConnect.Session{} = session, provers, opts \\ []) when is_list(provers) do
    maybe_install_build_tools!(session, opts)
    build_opts = Keyword.put(opts, :install_scripts, false)
    Map.new(provers, fn prover -> {prover.name, build!(session, prover, build_opts)} end)
  end

  @doc """
  Returns a JSON-friendly image preparation plan for display in Livebook.
  """
  @spec plan([Prover.t()]) :: [map()]
  def plan(provers) when is_list(provers) do
    Enum.map(provers, fn %Prover{} = prover ->
      container = Provers.container!(prover.name)

      %{
        prover: prover.name,
        image_name: container.image_name,
        local_def_path: local_def_path(container),
        docker_image: container.docker_image,
        source_url: container.source_url,
        notes: container.notes
      }
    end)
  end

  defp build_plan_entry(%HpcConnect.Session{} = session, %Prover{} = prover, opts) do
    container = Provers.container!(prover.name)

    %{
      prover: prover.name,
      image_name: container.image_name,
      def_name: remote_image_name(prover),
      local_def_path: local_def_path(container),
      local_def_exists?: File.exists?(local_def_path(container)),
      remote_def_path: remote_def_path(session, prover),
      remote_sif_path: remote_sif_path(session, prover),
      build_cluster: Keyword.get(opts, :build_cluster, :hpc_connect_default_fallbacks),
      use_slurm: Keyword.get(opts, :use_slurm, false),
      source_url: container.source_url,
      notes: container.notes
    }
  end

  defp build_opts(%Prover{} = prover, opts) do
    [
      name: remote_image_name(prover),
      local_def_path: local_def_path(prover),
      force_rebuild: Keyword.get(opts, :force_rebuild, false),
      timeout: Keyword.get(opts, :timeout, 3_600_000),
      interval: Keyword.get(opts, :interval, 15_000)
    ]
    |> maybe_put(:build_cluster, Keyword.fetch(opts, :build_cluster))
    |> maybe_put(:use_slurm, Keyword.fetch(opts, :use_slurm))
    |> maybe_put(:partition, Keyword.fetch(opts, :partition))
    |> maybe_put(:walltime, Keyword.fetch(opts, :walltime))
    |> maybe_put(:cpus, Keyword.fetch(opts, :cpus))
    |> maybe_put(:apptainer_tmpdir, Keyword.fetch(opts, :apptainer_tmpdir))
  end

  defp maybe_put(opts, _key, :error), do: opts
  defp maybe_put(opts, key, {:ok, value}), do: Keyword.put(opts, key, value)

  defp maybe_install_build_tools!(session, opts) do
    if Keyword.get(opts, :install_scripts, true) do
      install_build_tools!(session, opts)
    else
      :ok
    end
  end

  defp remote_image_name(%Prover{sif_name: name, name: prover_name}) do
    case name do
      value when is_binary(value) and value != "" -> value
      _ -> Atom.to_string(prover_name)
    end
  end

  defp normalize_prover(%Prover{} = prover), do: prover
  defp normalize_prover(name), do: Provers.fetch!(name)
end
