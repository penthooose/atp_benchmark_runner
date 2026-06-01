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

  defp bundled_example_paths do
    :atp_benchmark_runner
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("tptp_examples/*.{p,ax}")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
