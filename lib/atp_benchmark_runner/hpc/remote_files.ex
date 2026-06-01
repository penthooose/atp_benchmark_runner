defmodule AtpBenchmarkRunner.HPC.RemoteFiles do
  @moduledoc """
  Small remote file operations over `hpc_connect` SSH sessions.

  `hpc_connect` intentionally focuses on generic SSH/SCP execution. This module
  adds the benchmark-specific reads/listing we need for result collection without
  extending or mutating the dependency.
  """

  alias AtpBenchmarkRunner.HPC.{JobScript, Shell}

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
  """
  @spec write_text!(HpcConnect.Session.t(), binary(), binary(), keyword()) :: binary()
  def write_text!(%HpcConnect.Session{} = session, remote_path, content, opts \\ []) do
    HpcConnect.connect!(
      session,
      JobScript.write_file_command(remote_path, content, mode: Keyword.get(opts, :mode, "644")),
      connect_opts(opts)
    )
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
