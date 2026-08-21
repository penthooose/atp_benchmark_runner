defmodule AtpBenchmarkRunner.HPC.RemoteFiles do
  @moduledoc """
  Small remote file operations over `hpc_connect` SSH sessions.

  `hpc_connect` intentionally focuses on generic SSH/SCP execution. This module
  adds the benchmark-specific reads/listing we need for result collection without
  extending or mutating the dependency.
  """

  alias AtpBenchmarkRunner.HPC.{JobScript, Shell}

  # Safe base64 characters per SSH command line. 16 000 chars + env exports +
  # shell overhead stays comfortably below the ~32 767-char Windows limit while
  # keeping the number of round-trips small.
  @max_base64_per_call 16_000

  @doc """
  Lists remote files below `remote_dir` matching a shell `find -name` pattern.
  """
  @spec list(HpcConnect.Session.t(), binary(), binary(), keyword()) :: [binary()]
  def list(%HpcConnect.Session{} = session, remote_dir, pattern \\ "*", opts \\ []) do
    command =
      "if [ -d #{Shell.quote(remote_dir)} ]; then find #{Shell.quote(remote_dir)} -type f -name #{Shell.quote(pattern)} | sort; fi"

    session
    |> HpcConnect.connect!(command, connect_opts(opts))
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Checks whether a remote path exists.
  """
  @spec exists?(HpcConnect.Session.t(), binary(), keyword()) :: boolean()
  def exists?(%HpcConnect.Session{} = session, remote_path, opts \\ []) do
    output =
      HpcConnect.connect!(
        session,
        "test -e #{Shell.quote(remote_path)} && echo yes || echo no",
        connect_opts(opts)
      )

    String.trim(output) == "yes"
  end

  @doc """
  Reads a remote text file via base64 to avoid quoting/newline problems.
  """
  @spec read_text!(HpcConnect.Session.t(), binary(), keyword()) :: binary()
  def read_text!(%HpcConnect.Session{} = session, remote_path, opts \\ []) do
    output =
      HpcConnect.connect!(
        session,
        "base64 -w 0 #{Shell.quote(remote_path)}",
        connect_opts(opts)
      )

    output
    |> String.trim()
    |> Base.decode64!()
  end

  @doc """
  Writes a text file remotely using the same base64 strategy as job scripts.

  Large payloads are delivered in base64 chunks across several small SSH calls
  so no single command line exceeds the OS process-spawn limit (Windows
  `CreateProcess` caps it at ~32 767 chars). Without chunking, big files such as
  the single-node tasks list fail to spawn `ssh.exe` with `:eacces`.
  """
  @spec write_text!(HpcConnect.Session.t(), binary(), binary(), keyword()) :: :ok | binary()
  def write_text!(%HpcConnect.Session{} = session, remote_path, content, opts \\ []) do
    mode = Keyword.get(opts, :mode, "644")
    b64 = content |> String.replace("\r", "") |> Base.encode64()

    if byte_size(b64) <= @max_base64_per_call do
      # Small payload – single call, matches previous behaviour.
      HpcConnect.connect!(
        session,
        JobScript.write_file_command(remote_path, content, mode: mode),
        connect_opts(opts)
      )
    else
      b64
      |> chunk_write_commands(remote_path, mode)
      |> Enum.each(fn cmd -> HpcConnect.connect!(session, cmd, connect_opts(opts)) end)

      :ok
    end
  end

  @doc """
  Pure builder of the remote shell commands that write `b64` (base64 text) to
  `remote_path`, chunked so each command line stays small.

  - chunk 0 truncates the target (`>`), the rest append (`>>`)
  - a final `chmod` command applies `mode` when given

  Exposed for tests; callers should use `write_text!/4`.
  """
  @spec chunk_write_commands(binary(), binary(), binary() | nil) :: [binary()]
  def chunk_write_commands(b64, remote_path, mode \\ "644") do
    dir = posix_dirname(remote_path)
    dir_cmd = "mkdir -p #{Shell.quote(dir)}"

    chunks =
      b64
      |> chunk_base64(@max_base64_per_call)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        redirect = if index == 0, do: ">", else: ">>"

        "#{dir_cmd} && printf %s #{Shell.quote(chunk)} | base64 -d #{redirect} #{Shell.quote(remote_path)}"
      end)

    if mode do
      chunks ++ ["chmod #{mode} #{Shell.quote(remote_path)}"]
    else
      chunks
    end
  end

  # Splits a base64 binary into chunks of at most `size` bytes.
  defp chunk_base64(b64, size) when byte_size(b64) <= size, do: [b64]

  defp chunk_base64(b64, size) do
    <<head::binary-size(size), rest::binary>> = b64
    [head | chunk_base64(rest, size)]
  end

  defp posix_dirname(path) do
    normalized = String.replace(path, "\\", "/")

    normalized
    |> String.split("/", trim: true)
    |> Enum.drop(-1)
    |> case do
      [] ->
        if String.starts_with?(normalized, "/"), do: "/", else: "."

      parts ->
        if String.starts_with?(normalized, "/"),
          do: "/" <> Enum.join(parts, "/"),
          else: Enum.join(parts, "/")
    end
  end

  @doc """
  Ensures a remote directory exists.
  """
  @spec mkdir_p!(HpcConnect.Session.t(), binary(), keyword()) :: binary()
  def mkdir_p!(%HpcConnect.Session{} = session, remote_dir, opts \\ []) do
    HpcConnect.connect!(session, "mkdir -p #{Shell.quote(remote_dir)}", connect_opts(opts))
  end

  defp connect_opts(opts), do: Keyword.get(opts, :connect_opts, [])
end
