defmodule AtpBenchmarkRunner.TPTP do
  @moduledoc """
  TPTP problem library management.

  Supports three practical workflows:

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
  """
  @spec install_examples!(keyword()) :: [binary()]
  def install_examples!(opts \\ []) do
    destination =
      Keyword.get(opts, :destination, Path.join(default_root(opts), "bundled_examples"))

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
    1. The configured TPTP library root (`Problems/<domain>/<name>`, `Axioms/<domain>/<name>`)
    2. The bundled `priv/tptp_examples/` directory
    3. As a direct file path

  Accepts names like `"GRP001-0.p"`, `"problems/ana/ANA002-4.p"`,
  `"axioms/AGT001+2.ax"`, or a full/relative path.
  """
  @spec resolve_problem_name(binary(), keyword()) :: binary() | nil
  def resolve_problem_name(name, opts \\ []) when is_binary(name) do
    basename = Path.basename(name)

    # Candidates in priority order
    candidates = [
      # Explicit path with Problems/ or Axioms/ prefix
      fn -> resolve_in_tptp_root(name, opts) end,
      # Bare name in Problems subdirectories
      fn -> resolve_in_tptp_root("Problems/**/#{basename}", opts) end,
      # Bare name in Axioms subdirectories
      fn -> resolve_in_tptp_root("Axioms/**/#{basename}", opts) end,
      # Bundled priv/tptp_examples
      fn -> resolve_bundled(basename) end,
      # Direct path
      fn -> if File.exists?(name), do: Path.expand(name) end
    ]

    Enum.find_value(candidates, & &1.())
  end

  @doc """
  Selects benchmark problems flexibly.

  Accepts a keyword list (options below) or a plain list of TPTP names:

      # Plain name list — shortest form
      AtpBenchmarkRunner.TPTP.select(["ANA002-4.p", "GRP001-0.p"])

      # Keyword with explicit names
      AtpBenchmarkRunner.TPTP.select(names: ["ANA002-4.p"])

      # Rating-filtered from archive (falls back to bundled examples)
      AtpBenchmarkRunner.TPTP.select(rating_max: 0.1, limit: 15)

  ## Options

    * `:names` — explicit list of TPTP problem names/paths to load.
      Also accepted as a bare list (first argument, no keyword wrapper).

    * `:root_dir` — TPTP archive root (auto-detected; falls back to bundled).

    * `:limit` — max number of problems (default from archive: 15, bundled: all).

    * `:rating_min`, `:rating_max` — rating filter (only when `:names` is not set).

    * `:logics`, `:domains`, `:statuses` — additional filters.

  When no archive is found at `:root_dir` and no names are given, falls back
  to the bundled `priv/tptp_examples` automatically.
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
        Enum.map(names, fn name ->
          path = resolve_problem_name(name, opts)
          Problem.from_tptp_file(path, source: :tptp_name)
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
      candidate =
        root
        |> Path.join(pattern)
        |> Path.wildcard()
        |> List.first()

      if candidate && File.exists?(candidate), do: candidate
    end
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

  defp bundled_example_paths do
    :atp_benchmark_runner
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("tptp_examples/*.{p,ax}")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
