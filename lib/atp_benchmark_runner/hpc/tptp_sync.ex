defmodule AtpBenchmarkRunner.HPC.TPTPSync do
  @moduledoc """
  Synchronises selected local TPTP files to a remote HPC-visible directory.

  The default target is the session vault under `atp_benchmark_runner/tptp`, but
  callers should pass `remote_tptp_dir:` for cluster-specific storage such as a
  Helma `/hnvme` workspace when needed.
  """

  alias AtpBenchmarkRunner.Problem
  alias AtpBenchmarkRunner.HPC.{RemoteFiles, Shell}

  @doc """
  Returns the remote TPTP root used for sync/check operations.
  """
  @spec remote_root(HpcConnect.Session.t(), keyword()) :: binary()
  def remote_root(%HpcConnect.Session{} = session, opts \\ []) do
    Keyword.get(opts, :remote_tptp_dir) ||
      posix_join([session.vault_dir || session.work_dir, "atp_benchmark_runner", "tptp"])
  end

  @doc """
  Builds a JSON-friendly sync plan without touching the cluster.
  """
  @spec plan(HpcConnect.Session.t(), [Problem.t()], keyword()) :: map()
  def plan(%HpcConnect.Session{} = session, problems, opts \\ []) when is_list(problems) do
    root = remote_root(session, opts)

    %{
      remote_tptp_dir: root,
      total_problems: length(problems),
      local_files: Enum.count(problems, &local_file?/1),
      already_remote: Enum.count(problems, &already_remote?/1),
      entries: Enum.map(problems, &plan_entry(&1, root))
    }
  end

  @doc """
  Uploads selected local problem files and returns problems with remote paths.

  Batches the remote existence check into a single `find` command instead of
  one SSH call per file — avoids rate-limiting the SSH gateway.
  """
  @spec sync_problem_set!(HpcConnect.Session.t(), [Problem.t()], keyword()) :: [Problem.t()]
  def sync_problem_set!(%HpcConnect.Session{} = session, problems, opts \\ [])
      when is_list(problems) do
    root = remote_root(session, opts)
    RemoteFiles.mkdir_p!(session, root, opts)

    # One SSH call to discover all already-synced remote files
    existing = existing_remote_paths(session, root)

    Enum.map(problems, &sync_problem!(session, &1, root, existing, opts))
  end

  defp existing_remote_paths(%HpcConnect.Session{} = session, root) do
    command =
      "if [ -d #{Shell.quote(root)} ]; then find #{Shell.quote(root)} -type f -name '*.p' -o -name '*.ax' -o -name '*.smt2' 2>/dev/null; fi"

    session
    |> HpcConnect.connect!(command)
    |> String.split("\n", trim: true)
    |> MapSet.new()
  end

  @doc """
  Checks the remote synced TPTP directory.
  """
  @spec check_remote(HpcConnect.Session.t(), keyword()) :: map()
  def check_remote(%HpcConnect.Session{} = session, opts \\ []) do
    root = remote_root(session, opts)

    command = """
    if [ -d #{Shell.quote(root)} ]; then
      printf 'exists=true\n'
      printf 'files='; find #{Shell.quote(root)} -type f \( -name '*.p' -o -name '*.ax' \) | wc -l
      printf 'bytes='; du -sb #{Shell.quote(root)} 2>/dev/null | awk '{print $1}'
    else
      printf 'exists=false\nfiles=0\nbytes=0\n'
    fi
    """

    session
    |> HpcConnect.connect!(command, Keyword.get(opts, :connect_opts, []))
    |> parse_key_values()
    |> Map.put(:remote_tptp_dir, root)
  end

  defp sync_problem!(session, %Problem{} = problem, root, existing, opts) do
    cond do
      local_file?(problem) ->
        remote_path = remote_problem_path(problem, root)

        if MapSet.member?(existing, remote_path) do
          mark_synced(problem, remote_path)
        else
          RemoteFiles.mkdir_p!(session, posix_dirname(remote_path), opts)

          # Upload the original problem file
          HpcConnect.SSH.upload!(session, problem.path, remote_path,
            normalize_line_endings: :lf,
            normalize_extensions: [".p", ".ax"]
          )

          # Also upload converted versions needed by specific provers
          upload_converted!(session, problem.path, remote_path, ".smt2", opts)
          upload_thf_converted!(session, problem.path, remote_path, opts)

          mark_synced(problem, remote_path)
        end

      already_remote?(problem) ->
        problem

      true ->
        problem
    end
  end

  # Upload a .smt2 conversion if it exists (generated for CVC5)
  defp upload_converted!(session, local_path, remote_path, ext, _opts) do
    converted =
      local_path
      |> String.replace_suffix(".p", ext)
      |> String.replace_suffix(".tptp", ext)

    if File.exists?(converted) do
      remote_converted =
        remote_path
        |> String.replace_suffix(".p", ext)
        |> String.replace_suffix(".tptp", ext)

      HpcConnect.SSH.upload!(session, converted, remote_converted,
        normalize_line_endings: :lf,
        normalize_extensions: [ext]
      )
    end
  end

  # Upload a _thf.p converted file if it exists (generated for Lash)
  defp upload_thf_converted!(session, local_path, remote_path, _opts) do
    thf_local =
      local_path
      |> String.replace_suffix(".p", "_thf.p")
      |> String.replace_suffix(".tptp", "_thf.p")

    if File.exists?(thf_local) do
      thf_remote =
        remote_path
        |> String.replace_suffix(".p", "_thf.p")
        |> String.replace_suffix(".tptp", "_thf.p")

      HpcConnect.SSH.upload!(session, thf_local, thf_remote,
        normalize_line_endings: :lf,
        normalize_extensions: [".p"]
      )
    end
  end

  defp plan_entry(%Problem{} = problem, root) do
    %{
      problem_id: problem.id,
      source_path: problem.path,
      remote_path:
        if(local_file?(problem), do: remote_problem_path(problem, root), else: problem.path),
      upload?: local_file?(problem)
    }
  end

  defp mark_synced(%Problem{} = problem, remote_path) do
    %{
      problem
      | path: remote_path,
        source: :remote,
        metadata:
          Map.merge(problem.metadata, %{
            local_path: problem.path,
            remote_path: remote_path,
            synced_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          })
    }
  end

  defp remote_problem_path(%Problem{} = problem, root) do
    relative =
      Map.get(problem.metadata, :relative_path) || Map.get(problem.metadata, "relative_path")

    relative = normalize_relative_path(relative || Path.basename(problem.path || problem.name))
    posix_join([root, relative])
  end

  defp local_file?(%Problem{path: path}) when is_binary(path), do: File.exists?(path)
  defp local_file?(_), do: false

  defp already_remote?(%Problem{source: :remote, path: path}) when is_binary(path), do: true
  defp already_remote?(_), do: false

  defp normalize_relative_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
  end

  defp parse_key_values(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {known_check_key(key), normalize_value(value)}
    end)
  end

  defp known_check_key("exists"), do: :exists
  defp known_check_key("files"), do: :files
  defp known_check_key("bytes"), do: :bytes
  defp known_check_key(other), do: other

  defp normalize_value("true"), do: true
  defp normalize_value("false"), do: false

  defp normalize_value(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> String.trim(value)
    end
  end

  defp posix_dirname(path) do
    normalized = String.replace(path, "\\", "/")

    normalized
    |> String.split("/", trim: true)
    |> Enum.drop(-1)
    |> case do
      [] -> if String.starts_with?(normalized, "/"), do: "/", else: "."
      parts -> posix_join(if String.starts_with?(normalized, "/"), do: ["/" | parts], else: parts)
    end
  end

  defp posix_join(parts) do
    joined =
      parts
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim(&1, "/"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("/")

    ensure_absolute(joined, parts)
  end

  defp ensure_absolute(path, [first | _]) do
    if String.starts_with?(to_string(first), "/"), do: "/" <> path, else: path
  end
end
