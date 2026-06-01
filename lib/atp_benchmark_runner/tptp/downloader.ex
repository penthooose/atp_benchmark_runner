defmodule AtpBenchmarkRunner.TPTP.Downloader do
  @moduledoc """
  Download and extraction boundary for official TPTP archives.

  Network and archive operations are isolated here so tests can inject a fake
  downloader and the Livebook UI can make the large download an explicit choice.
  """

  alias AtpBenchmarkRunner.TPTP.Archive

  @doc """
  Returns the local archive path for a TPTP archive.
  """
  @spec archive_path(Archive.t(), keyword()) :: binary()
  def archive_path(%Archive{} = archive, opts) do
    root_dir = Keyword.fetch!(opts, :root_dir)
    Path.join([root_dir, "downloads", archive.archive_name])
  end

  @doc """
  Returns the expected extraction directory for a TPTP archive.
  """
  @spec install_dir(Archive.t(), keyword()) :: binary()
  def install_dir(%Archive{} = archive, opts) do
    root_dir = Keyword.fetch!(opts, :root_dir)
    Path.join(root_dir, "TPTP-v#{archive.version}")
  end

  @doc """
  Returns true when the archive appears to be extracted.
  """
  @spec installed?(Archive.t(), keyword()) :: boolean()
  def installed?(%Archive{} = archive, opts) do
    archive
    |> install_dir(opts)
    |> Path.join("Problems")
    |> File.dir?()
  end

  @doc """
  Downloads the archive unless it already exists locally.
  """
  @spec download_archive(Archive.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_archive(%Archive{} = archive, opts) do
    path = archive_path(archive, opts)
    force? = Keyword.get(opts, :force, false)

    cond do
      File.exists?(path) and not force? ->
        {:ok, path}

      true ->
        File.mkdir_p!(Path.dirname(path))
        download_fun = Keyword.get(opts, :download_fun, &default_download/2)
        download_fun.(archive.url, path)
    end
  end

  @doc """
  Extracts a downloaded `.tgz` archive into the root directory.
  """
  @spec extract_archive(Archive.t(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def extract_archive(%Archive{} = archive, archive_path, opts) do
    destination = install_dir(archive, opts)
    force? = Keyword.get(opts, :force, false)

    cond do
      installed?(archive, opts) and not force? ->
        {:ok, destination}

      not File.exists?(archive_path) ->
        {:error, {:missing_archive, archive_path}}

      true ->
        File.mkdir_p!(Keyword.fetch!(opts, :root_dir))

        case :erl_tar.extract(String.to_charlist(archive_path), [
               :compressed,
               {:cwd, String.to_charlist(Keyword.fetch!(opts, :root_dir))}
             ]) do
          :ok -> {:ok, destination}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Downloads and extracts the archive.
  """
  @spec ensure_archive(Archive.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def ensure_archive(%Archive{} = archive, opts) do
    with {:ok, archive_path} <- download_archive(archive, opts) do
      extract_archive(archive, archive_path, opts)
    end
  end

  defp default_download(url, path) do
    tmp_path = path <> ".part"
    File.rm(tmp_path)

    if Code.ensure_loaded?(Req) do
      case Req.get(url, into: File.stream!(tmp_path, [:write, :binary])) do
        {:ok, %{status: status}} when status in 200..299 ->
          File.rename!(tmp_path, path)
          {:ok, path}

        {:ok, %{status: status}} ->
          File.rm(tmp_path)
          {:error, {:http_status, status}}

        {:error, reason} ->
          File.rm(tmp_path)
          {:error, reason}
      end
    else
      {:error, :req_not_available}
    end
  end
end
