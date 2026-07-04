defmodule AtpBenchmarkRunner.TPTP do
  @moduledoc """
  TPTP problem library management.

  Supports four practical workflows:

  - drop user-supplied TPTP files into `./tmp/tptp_user_examples/` (highest priority)
  - use already copied local TPTP files, such as `tmp/tptp_problems`
  - install bundled tiny smoke examples from `priv/tptp_examples`
  - explicitly download and extract the official full TPTP archive
  """

  alias AtpBenchmarkRunner.{Config, Problem}
  alias AtpBenchmarkRunner.TPTP.{Archive, Downloader, Index}

  @doc """
  Returns official TPTP archive choices known to the runner.
  """
  @spec available_archives() :: [Archive.t()]
  def available_archives, do: Archive.available()

  @doc """
  Returns the default official TPTP archive.
  """
  @spec default_archive() :: Archive.t()
  def default_archive, do: Archive.full()

  @doc """
  Returns the configured local TPTP root directory.
  """
  @spec default_root(keyword()) :: binary()
  def default_root(opts \\ []), do: Config.tptp_dir(opts)

  @doc """
  Returns the detected extracted TPTP library root.
  """
  @spec library_root(keyword()) :: binary()
  def library_root(opts \\ []) do
    opts
    |> root_opts()
    |> Keyword.fetch!(:root_dir)
    |> Index.library_root()
  end

  @doc """
  Returns true if the official archive appears to be extracted locally.
  """
  @spec installed?(keyword()) :: boolean()
  def installed?(opts \\ []) do
    archive = opts |> Keyword.get(:archive, default_archive()) |> Archive.normalize()
    Downloader.installed?(archive, root_opts(opts))
  end

  @doc """
  Downloads the selected official archive.
  """
  @spec download_archive(keyword()) :: {:ok, binary()} | {:error, term()}
  def download_archive(opts \\ []) do
    archive = opts |> Keyword.get(:archive, default_archive()) |> Archive.normalize()
    Downloader.download_archive(archive, root_opts(opts))
  end

  @doc """
  Downloads and extracts the selected official archive.
  """
  @spec ensure_archive(keyword()) :: {:ok, binary()} | {:error, term()}
  def ensure_archive(opts \\ []) do
    archive = opts |> Keyword.get(:archive, default_archive()) |> Archive.normalize()
    Downloader.ensure_archive(archive, root_opts(opts))
  end

  @doc """
  Installs bundled tiny TPTP-style examples into the configured root.

  Default destination resolves as follows:
    - `:destination` option if given
    - `bundled_dir/1` (auto-populated tmp dir, `./tmp/tptp_examples`)
    - Falls back to `root_dir/bundled_examples` if `:root_dir` option is given

  The tmp bundled dir (`bundled_dir/0`) is auto-populated on first
  `select`/`resolve_problem_name` call anyway, so explicit installation
  is only needed for custom locations.
  """
  @spec install_examples!(keyword()) :: [binary()]
  def install_examples!(opts \\ []) do
    destination =
      cond do
        Keyword.has_key?(opts, :destination) ->
          Keyword.fetch!(opts, :destination)

        Keyword.has_key?(opts, :root_dir) ->
          Path.join(Keyword.fetch!(opts, :root_dir), "bundled_examples")

        true ->
          bundled_dir()
      end

    force? = Keyword.get(opts, :force, false)
    File.mkdir_p!(destination)

    bundled_example_paths()
    |> Enum.map(fn source ->
      target = Path.join(destination, Path.basename(source))

      if force? or not File.exists?(target) do
        File.cp!(source, target)
      end

      target
    end)
  end

  @doc """
  Returns bundled example problems without copying them.
  """
  @spec bundled_examples() :: [Problem.t()]
  def bundled_examples do
    bundled_example_paths()
    |> Enum.map(&Problem.from_tptp_file(&1, source: :bundled))
  end

  @doc """
  Resolves a TPTP problem name to an actual file path.

  Searches in order:
    1. The user examples tmp dir (`./tmp/tptp_user_examples/`) — highest priority
    2. The bundled examples tmp dir (`./tmp/tptp_examples/`) — fast, no index needed
    3. The configured TPTP library root (`Problems/<domain>/<name>`, `Axioms/<domain>/<name>`)
    4. The legacy bundled `priv/tptp_examples/` directory
    5. As a direct file path

  Accepts names like `"GRP001-0.p"`, `"problems/ana/ANA002-4.p"`,
  `"axioms/AGT001+2.ax"`, or a full/relative path.
  """
  @spec resolve_problem_name(binary(), keyword()) :: binary() | nil
  def resolve_problem_name(name, opts \\ []) when is_binary(name) do
    basename = Path.basename(name)

    # Candidates in priority order
    candidates = [
      # User examples tmp dir (fast File.exists?, highest priority)
      fn -> resolve_in_user_dir(basename) end,
      # Bundled examples tmp dir (fast File.exists?, no index needed)
      fn -> resolve_in_bundled_dir(basename) end,
      # Explicit path with Problems/ or Axioms/ prefix
      fn -> resolve_in_tptp_root(name, opts) end,
      # Bare name in Problems subdirectories
      fn -> resolve_in_tptp_root("Problems/**/#{basename}", opts) end,
      # Bare name in Axioms subdirectories
      fn -> resolve_in_tptp_root("Axioms/**/#{basename}", opts) end,
      # Legacy bundled priv/tptp_examples
      fn -> resolve_bundled(basename) end,
      # Direct path
      fn -> if File.exists?(name), do: Path.expand(name) end
    ]

    Enum.find_value(candidates, & &1.())
  end

  @doc """
  Select benchmark problems by name list or filter options.

      # By name
      AtpBenchmarkRunner.TPTP.select(["ANA002-4.p", "GRP001-0.p"])

      # By filter (requires full archive)
      AtpBenchmarkRunner.TPTP.select(rating_max: 0.1, limit: 15)

  Options: `:names`, `:root_dir`, `:limit`, `:rating_min`, `:rating_max`,
  `:logics`, `:domains`, `:statuses`. Falls back to bundled examples when
  no archive is found.
  """
  @spec select(keyword() | [binary()]) :: [Problem.t()]
  def select(opts \\ []) do
    names =
      cond do
        # Plain list of strings → bare name list
        Keyword.keyword?(opts) == false and is_list(opts) -> opts
        # Keyword list with :names key
        Keyword.has_key?(opts, :names) -> Keyword.fetch!(opts, :names)
        # Neither
        true -> nil
      end

    cond do
      is_list(names) and names != [] ->
        Enum.flat_map(names, fn name ->
          path = resolve_problem_name(name, opts)

          if path do
            [Problem.from_tptp_file(path, source: :tptp_name)]
          else
            user_dir = Config.user_examples_dir()
            bundled_dir = Config.bundled_examples_dir()

            IO.warn(
              "TPTP file not found, dropping: #{inspect(name)}\n" <>
                "  Checked directories:\n" <>
                "    #{user_dir}/\n" <>
                "    #{bundled_dir}/\n" <>
                "    TPTP library root (Problems/, Axioms/)\n" <>
                "  Drop your .p / .ax files into: #{user_dir}/",
              label: "AtpBenchmarkRunner.TPTP"
            )

            []
          end
        end)

      archive_available?(opts) ->
        load_problem_set(opts)

      true ->
        bundled = bundled_examples()
        limit = Keyword.get(opts, :limit, length(bundled))
        Enum.take(bundled, limit)
    end
  end

  @doc """
  Lists local TPTP files matching optional domain/form filters.
  """
  @spec list_files(keyword()) :: [binary()]
  def list_files(opts \\ []) do
    opts
    |> root_opts()
    |> Index.list_files()
  end

  @doc """
  Loads and filters local TPTP files as benchmark problems.
  """
  @spec load_problem_set(keyword()) :: [Problem.t()]
  def load_problem_set(opts \\ []) do
    opts
    |> root_opts()
    |> Index.load()
  end

  @doc """
  Returns summary counts for loaded problems.
  """
  @spec summarize([Problem.t()]) :: map()
  def summarize(problems), do: Index.summary(problems)

  defp root_opts(opts) do
    Keyword.put_new(opts, :root_dir, default_root(opts))
  end

  defp resolve_in_tptp_root(pattern, opts) do
    root = opts |> root_opts() |> Keyword.fetch!(:root_dir) |> Index.library_root()

    if root do
      basename = Path.basename(pattern)
      index = file_index(root)

      # Fast path: lookup from pre-built index
      case Map.fetch(index, basename) do
        {:ok, path} ->
          path

        :error ->
          # Fallback: explicit pattern (for paths with subdirectory prefix)
          candidate =
            root
            |> Path.join(pattern)
            |> Path.wildcard()
            |> List.first()

          if candidate && File.exists?(candidate), do: candidate
      end
    end
  end

  @doc false
  # Builds and caches a name→path index of all TPTP files under the library root.
  # Persisted as JSON on disk (survives kernel restarts) and cached in memory
  # via process dictionary (avoids re-reading the file for every name lookup).
  def file_index(root) when is_binary(root) do
    cache_key = {:tptp_file_index, root}

    case Process.get(cache_key) do
      nil ->
        index = load_or_build_index(root)
        Process.put(cache_key, index)
        index

      cached ->
        cached
    end
  end

  defp load_or_build_index(root) do
    cache_path = index_cache_path(root)

    if File.exists?(cache_path) do
      cache_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.new(fn {k, v} -> {k, v} end)
    else
      IO.puts("Building TPTP file index (one-time scan)...")
      index = build_file_index(root)
      File.mkdir_p!(Path.dirname(cache_path))
      File.write!(cache_path, Jason.encode!(index, pretty: true))
      index
    end
  end

  defp index_cache_path(root) do
    hash =
      root
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    tmp_root =
      AtpBenchmarkRunner.Config.store_dir(dir: "./tmp")
      |> Path.join("tptp_index")

    Path.join(tmp_root, "index_#{hash}.json")
  end

  defp build_file_index(root) do
    problems_root = Path.join(root, "Problems")
    axioms_root = Path.join(root, "Axioms")

    archive_index =
      cond do
        File.dir?(problems_root) ->
          ((Path.join(problems_root, "**/*.{p,ax}") |> Path.wildcard()) ++
             if(File.dir?(axioms_root),
               do: Path.join(axioms_root, "**/*.{p,ax}") |> Path.wildcard(),
               else: []
             ))
          |> Map.new(fn path -> {Path.basename(path), path} end)

        File.dir?(axioms_root) ->
          axioms_root
          |> Path.join("**/*.{p,ax}")
          |> Path.wildcard()
          |> Map.new(fn path -> {Path.basename(path), path} end)

        true ->
          %{}
      end

    # Always include bundled examples so they resolve instantly via the index,
    # even when no full archive is present.
    bundled_index =
      bundled_example_paths()
      |> Map.new(fn path -> {Path.basename(path), path} end)

    # Also scan the tmp bundled dir (auto-populated copy in ./tmp/tptp_examples)
    tmp_bundled_index =
      if File.dir?(Config.bundled_examples_dir()) do
        Config.bundled_examples_dir()
        |> Path.join("*.{p,ax}")
        |> Path.wildcard()
        |> Map.new(fn path -> {Path.basename(path), path} end)
      else
        %{}
      end

    # User examples dir — merged LAST so its entries override any duplicates
    # from archive or bundled sources.
    user_index =
      if File.dir?(Config.user_examples_dir()) do
        Config.user_examples_dir()
        |> Path.join("*.{p,ax}")
        |> Path.wildcard()
        |> Map.new(fn path -> {Path.basename(path), path} end)
      else
        %{}
      end

    archive_index
    |> Map.merge(bundled_index)
    |> Map.merge(tmp_bundled_index)
    |> Map.merge(user_index)
  end

  defp resolve_bundled(basename) do
    bundled_example_paths()
    |> Enum.find(&(Path.basename(&1) == basename))
  end

  defp archive_available?(opts) do
    root = opts |> root_opts() |> Keyword.fetch!(:root_dir)
    lib = Index.library_root(root)
    File.dir?(Path.join(lib, "Problems"))
  end

  @doc false
  # Returns the path to the tmp bundled examples directory.
  # Auto-populated on first access from priv/tptp_examples.
  def bundled_dir do
    dest = Config.bundled_examples_dir()
    ensure_bundled_dir_installed!(dest)
    dest
  end

  @doc false
  # Returns the path to the user examples directory (`./tmp/tptp_user_examples`).
  # Created if missing; users drop their own `.p` / `.ax` files here.
  def user_dir do
    dest = Config.user_examples_dir()
    File.mkdir_p!(dest)
    dest
  end

  defp ensure_bundled_dir_installed!(dest) do
    File.mkdir_p!(dest)

    # Only copy if the dir is empty (one-time auto-install)
    if File.ls!(dest) == [] do
      bundled_example_paths()
      |> Enum.each(fn source ->
        File.cp!(source, Path.join(dest, Path.basename(source)))
      end)
    end

    dest
  end

  defp resolve_in_user_dir(basename) do
    candidate = Path.join(user_dir(), basename)
    if File.exists?(candidate), do: candidate
  end

  defp resolve_in_bundled_dir(basename) do
    candidate = Path.join(bundled_dir(), basename)
    if File.exists?(candidate), do: candidate
  end

  defp bundled_example_paths do
    :atp_benchmark_runner
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("tptp_examples/*.{p,ax}")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "_thf.p"))
    |> Enum.sort()
  end
end
