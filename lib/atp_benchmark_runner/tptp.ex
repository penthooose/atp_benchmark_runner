defmodule AtpBenchmarkRunner.TPTP do
  @moduledoc """
  TPTP problem library management.

  Supports five practical workflows:

  - drop user-supplied TPTP files into `./tmp/tptp_user_examples/` (highest priority)
  - use already copied local TPTP files, such as `tmp/tptp_problems`
  - install bundled tiny smoke examples from `priv/tptp_examples`
  - download only specific named problems from the official TPTP web service
    (see `download_problems/2`)
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
  Downloads only the named TPTP problems instead of the full archive.

  Each name is resolved in two steps:

  1. **Official server** - fetched individually from the TPTP SeeTPTP CGI
     (`https://tptp.org/cgi-bin/SeeTPTP?Category=Problems&File=...`) and written
     to its archive-consistent path `<tptp_root>/Problems/<DOMAIN>/<NAME>.p`
     (axioms to `<tptp_root>/Axioms/<DOMAIN>/<NAME>.ax`), the same layout as an
     unpacked archive.
  2. **Local fallback (default on)** - a name the server does not have (e.g. a
     bundled smoke example that is not a real TPTP problem, or a renumbered
     name) is looked up in local sources instead of being declared unavailable:
     user examples dir, individually-downloaded dir, bundled examples
     (`priv/tptp_examples`, auto-copied into the bundled tmp dir on first use),
     then the installed TPTP root. If found, it is returned from its existing
     path; bundled smoke examples become usable from the bundled tmp dir
     without being copied into `<tptp_root>/Problems/`, so the real library is
     never polluted with stub files.

  Only names found in *neither* the server nor any local source become
  `%{name: ..., reason: {:not_found_anywhere, name}}` warnings. Set
  `bundled_fallback: false` for strict server-only behavior (a missing name then
  becomes a `{:not_found, name}` warning with no local lookup).

  Returns `{:ok, problems, warnings}` where `problems` is `[Problem.t()]` and
  `warnings` is a list of `%{name: binary(), reason: term()}` maps.

      {:ok, problems, warnings} =
        AtpBenchmarkRunner.TPTP.download_problems(["GRP001-1.p", "UNKNOWN-9.p"])

  Options: `:root_dir`, `:force`, `:bundled_fallback`, `:fetch_fun`
  (injectable for offline tests).
  """
  @spec download_problems([binary()], keyword()) ::
          {:ok, [Problem.t()], [%{name: binary(), reason: term()}]}
  def download_problems(names, opts \\ []) when is_list(names) and names != [] do
    bundled_fallback? = Keyword.get(opts, :bundled_fallback, true)

    {pairs, warnings} =
      Enum.reduce(names, {[], []}, fn name, {ok_acc, warn_acc} ->
        case download_one(name, bundled_fallback?, opts) do
          {:ok, path} ->
            {[{name, path} | ok_acc], warn_acc}

          {:warning, reason} ->
            {ok_acc, [%{name: Path.basename(name), reason: reason} | warn_acc]}
        end
      end)

    warn_download_failures(warnings)

    problems =
      pairs
      |> Enum.reverse()
      |> Enum.map(fn {_name, path} -> Problem.from_tptp_file(path, source: :downloaded) end)

    {:ok, problems, Enum.reverse(warnings)}
  end

  @doc """
  Like `download_problems/2` but returns `{problems, warnings}` directly for
  Livebook/manual use. Best-effort: names that cannot be obtained become
  warnings, never an exception.

      {problems, warnings} = AtpBenchmarkRunner.TPTP.download_problems!(names)
  """
  @spec download_problems!([binary()], keyword()) ::
          {[Problem.t()], [%{name: binary(), reason: term()}]}
  def download_problems!(names, opts \\ []) do
    case download_problems(names, opts) do
      {:ok, problems, warnings} -> {problems, warnings}
    end
  end

  defp download_one(name, bundled_fallback?, opts) do
    case Downloader.download_problem(name, opts) do
      {:ok, path} ->
        {:ok, path}

      {:error, {:not_found, _} = reason} ->
        if bundled_fallback? do
          case fallback_download(name, opts) do
            {:ok, path} -> {:ok, path}
            {:error, reason} -> {:warning, reason}
          end
        else
          {:warning, reason}
        end

      {:error, reason} ->
        {:warning, reason}
    end
  end

  defp fallback_download(name, opts) do
    case resolve_problem_name(name, opts) do
      nil ->
        {:error, {:not_found_anywhere, Path.basename(name)}}

      path ->
        # Return the resolved local path as-is (bundled examples tmp dir, a
        # user-dropped file, or an installed TPTP root). No copy into
        # <tptp_root>/Problems/ so bundled smoke stubs never pollute the real
        # library.
        {:ok, path}
    end
  end

  defp warn_download_failures([]), do: :ok

  defp warn_download_failures(warnings) do
    IO.warn(
      "TPTP single download: #{length(warnings)} problem(s) could not be downloaded:\n" <>
        Enum.map_join(warnings, "\n", fn w -> "  #{w.name}: #{inspect(w.reason)}" end),
      label: "AtpBenchmarkRunner.TPTP"
    )
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
    1. The user examples tmp dir (`./tmp/tptp_user_examples/`, highest priority)
    2. Individually downloaded problems (`<tptp_root>/Problems/<DOMAIN>/<name>`,
       `<tptp_root>/Axioms/<DOMAIN>/<name>`, see `download_problems/2`)
    3. The bundled examples tmp dir (`./tmp/tptp_examples/`, fast, no index needed)
    4. The configured TPTP library root (`Problems/<domain>/<name>`, `Axioms/<domain>/<name>`)
    5. The legacy bundled `priv/tptp_examples/` directory
    6. As a direct file path

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
      # Individually downloaded problems dir (see download_problems/2)
      fn -> resolve_in_single_download_dir(basename, opts) end,
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
        # Plain list of strings (bare name list)
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

  @doc false
  # Builds and caches a name-to-path index of all TPTP files under the library
  # root. Persisted as JSON on disk (survives kernel restarts) and cached in
  # memory via process dictionary (avoids re-reading the file per lookup).
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

    # User examples dir, merged last so its entries override duplicates from
    # archive or bundled sources.
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

  defp resolve_in_single_download_dir(basename, opts) do
    candidate = Downloader.problem_target(basename, opts)
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
