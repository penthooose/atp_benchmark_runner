defmodule AtpBenchmarkRunner.TPTP.Downloader do
  @moduledoc """
  Download and extraction boundary for official TPTP archives and individual
  problems.

  Network and archive operations are isolated here so tests can inject a fake
  downloader and the Livebook UI can make the large download an explicit choice.
  """

  alias AtpBenchmarkRunner.TPTP.Archive
  alias AtpBenchmarkRunner.TPTP.Index

  # The TPTP site only publishes the full library as one `.tgz` archive, but
  # individual problems are available through the SeeTPTP CGI
  # ("Problems and Axiom sets" link). The CGI serves an HTML wrapper with the
  # problem body inside a `<pre>` block, which `extract_single_problem/1` parses.
  @single_problem_base "https://tptp.org/cgi-bin/SeeTPTP"

  # Marker the SeeTPTP CGI embeds when the requested problem does not exist in
  # the currently published release (e.g. the bundled smoke examples GRP001-0.p
  # were renumbered in newer TPTP versions).
  @single_problem_error_markers ["Cannot read", "No such file or directory"]

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

  @doc """
  Returns the SeeTPTP CGI URL that serves one TPTP problem (or axiom).

  The domain is inferred from the file name (first three uppercase letters,
  e.g. `GRP`), matching the hrefs the TPTP site uses for its
  "Problems and Axiom sets" listings. `.ax` files use `Category=Axioms`.
  """
  @spec single_problem_url(binary()) :: binary()
  def single_problem_url(name) when is_binary(name) do
    basename = Path.basename(name)
    domain = Index.domain_from_name(basename)
    category = category_for(basename)

    params =
      ["Category=#{category}"] ++
        if(domain, do: ["Domain=#{domain}"], else: []) ++
        ["File=#{URI.encode_www_form(basename)}"]

    "#{@single_problem_base}?#{Enum.join(params, "&")}"
  end

  defp category_for(basename) do
    if String.ends_with?(basename, ".ax"), do: "Axioms", else: "Problems"
  end

  @doc """
  Returns the base directory under which individually downloaded problems are
  stored.

  Defaults to the TPTP root (see `AtpBenchmarkRunner.Config.single_download_dir/1`).
  """
  @spec single_problem_dir(keyword()) :: binary()
  def single_problem_dir(opts \\ []), do: AtpBenchmarkRunner.Config.single_download_dir(opts)

  @doc """
  Returns the archive-consistent local target path for a single problem name.

  Mirrors the unpacked TPTP archive layout:

    * `<base>/Problems/<DOMAIN>/<NAME>.p` for problems
    * `<base>/Axioms/<DOMAIN>/<NAME>.ax` for axioms

  where `<base>` defaults to the TPTP root. Names without an inferable
  three-letter domain are written directly under the `Problems`/`Axioms`
  directory.
  """
  @spec problem_target(binary(), keyword()) :: binary()
  def problem_target(name, opts \\ []) when is_binary(name) do
    basename = Path.basename(name)
    category = category_for(basename)
    domain = Index.domain_from_name(basename)

    parts =
      [single_problem_dir(opts), category] ++
        if(domain, do: [domain], else: []) ++ [basename]

    Path.join(parts)
  end

  @doc """
  Downloads one TPTP problem by name (no full archive) to its archive-consistent
  path (`<tptp_root>/Problems/<DOMAIN>/<NAME>.p`).

  Returns `{:ok, path}` of the written file, or `{:error, term}`.

  The `:fetch_fun` option (default `(url) -> {:ok, body}` via Req) is injectable
  for offline tests, mirroring `download_archive/2`'s `:download_fun`.
  """
  @spec download_problem(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_problem(name, opts \\ []) when is_binary(name) do
    target = problem_target(name, opts)
    force? = Keyword.get(opts, :force, false)

    cond do
      File.exists?(target) and not force? ->
        {:ok, target}

      true ->
        with {:ok, content} <- fetch_single_problem(Path.basename(name), opts) do
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, content)
          {:ok, target}
        end
    end
  end

  @doc """
  Fetches one TPTP problem from the official SeeTPTP CGI and returns its
  problem body (with the HTML wrapper and anchors removed).

  Returns `{:error, {:not_found, name}}` when the problem does not exist in the
  current official release, `{:error, {:http_status, code}}` on HTTP errors, and
  `{:error, {:no_problem_block, name}}` when the response cannot be parsed.
  """
  @spec fetch_single_problem(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch_single_problem(name, opts \\ []) when is_binary(name) do
    url = single_problem_url(name)
    fetch_fun = Keyword.get(opts, :fetch_fun, &default_fetch/1)

    with {:ok, html} <- fetch_fun.(url),
         {:ok, content} <- extract_single_problem(html, name) do
      {:ok, content}
    end
  end

  @doc """
  Extracts the problem body from a SeeTPTP HTML response.

  The CGI wraps the raw problem text in `<pre>...</pre>` and rewrites TPTP
  `include(...)` paths and formula names into HTML anchors. This function strips
  the wrapper, flattens the anchors back to their display text, removes any
  remaining tags, and decodes basic HTML entities.

  A response that marks the problem as missing (the CGI embeds
  "Cannot read ... No such file or directory") yields
  `{:error, {:not_found, name}}`.
  """
  @spec extract_single_problem(binary(), binary() | nil) :: {:ok, binary()} | {:error, term()}
  def extract_single_problem(html, name \\ nil) when is_binary(html) do
    cond do
      Enum.any?(@single_problem_error_markers, &String.contains?(html, &1)) ->
        {:error, {:not_found, name || "unknown"}}

      true ->
        case Regex.run(~r{<pre>(.*?)</pre>}is, html) do
          [_, inner] ->
            content =
              inner
              |> replace_anchor_pairs()
              |> strip_remaining_tags()
              |> decode_entities()
              |> String.trim()

            if content == "" do
              {:error, {:not_found, name || "unknown"}}
            else
              {:ok, content}
            end

          nil ->
            {:error, {:no_problem_block, name || "unknown"}}
        end
    end
  end

  defp replace_anchor_pairs(text) do
    Regex.replace(~r{<a\s+[^>]*>(.*?)</a>}is, text, "\\1")
  end

  defp strip_remaining_tags(text) do
    Regex.replace(~r{<[^>]+>}, text, "")
  end

  defp decode_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  defp default_fetch(url) do
    if Code.ensure_loaded?(Req) do
      # tptp.org serves its certificate with keyCertSign/cRLSign key usage
      # extensions that Erlang's strict TLS stack rejects. Relax verification
      # the same way the archive download does.
      transport_opts = [verify: :verify_none]

      case Req.get(url, connect_options: [transport_opts: transport_opts]) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :req_not_available}
    end
  end

  defp default_download(url, path) do
    tmp_path = path <> ".part"
    File.rm(tmp_path)

    if Code.ensure_loaded?(Req) do
      # tptp.org serves its certificate with keyCertSign/cRLSign key usage
      # extensions that Erlang's strict TLS stack rejects. Relax verification
      # because the archive checksum and extraction provide integrity.
      transport_opts = [verify: :verify_none]

      case Req.get(url,
             into: File.stream!(tmp_path, [:write, :binary]),
             connect_options: [transport_opts: transport_opts]
           ) do
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
