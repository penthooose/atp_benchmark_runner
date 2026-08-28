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

  # Upper bound for a batched multi-file write command line (the joined
  # `&&`-chain of per-file write steps). Stays safely below the Windows
  # process-spawn limit of ~32 767 chars while grouping several small files
  # into one SSH call.
  @max_batch_command_size 28_000

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

    cond do
      byte_size(b64) <= @max_base64_per_call ->
        # Small payload: single call, matches previous behaviour.
        HpcConnect.connect!(
          session,
          JobScript.write_file_command(remote_path, content, mode: mode),
          connect_opts(opts)
        )

      Keyword.get(opts, :single_command, false) ->
        # Steady-shell only: deliver the whole payload as ONE command via stdin.
        # The steady shell has no Windows process-spawn limit (no fresh ssh.exe
        # per chunk), so several rapid writes collapse into a single call. Only
        # safe over the steady shell; a joined command this large would exceed
        # the ~32 767 char limit as an ssh argument in non-steady mode.
        cmd =
          b64
          |> chunk_write_commands(remote_path, mode)
          |> Enum.join(" && ")

        HpcConnect.connect!(session, cmd, connect_opts(opts))
        :ok

      true ->
        b64
        |> chunk_write_commands(remote_path, mode)
        |> Enum.each(fn cmd -> HpcConnect.connect!(session, cmd, connect_opts(opts)) end)

        :ok
    end
  end

  @doc """
  Uploads a local text file to `remote_path` by streaming it as base64 over the
  SSH session (routed through the steady shell when enabled), with no `scp`, so
  uploads never open a fresh per-file connection that can trip the gateway rate
  limiter. CRLF is normalized to LF and large files are chunked into several
  small SSH calls.

  Used for TPTP problem files and their SMT/THF conversions in the benchmark
  sync (`TPTPSync`).
  """
  @spec upload_file!(HpcConnect.Session.t(), binary(), binary(), keyword()) :: :ok
  def upload_file!(%HpcConnect.Session{} = session, local_path, remote_path, opts \\ []) do
    mode = Keyword.get(opts, :mode, "644")
    content = local_path |> File.read!() |> String.replace("\r", "")
    _ = write_text!(session, remote_path, content, mode: mode)
    :ok
  end

  @doc """
  Uploads many local files to their remote paths in a minimal number of SSH
  commands (batched base64, routed through the steady shell when enabled).

  `files` is a list of `{local_path, remote_path}`. All writes are grouped into
  a handful of `connect!` calls instead of one per file. The benchmark sync
  phase is the main source of the SSH-call burst that trips the csnhr gateway
  rate limiter (dozens of fresh connections in a short window can cause
  `Connection refused` for the whole user). CRLF is normalized to LF per file.
  """
  @spec upload_files!(HpcConnect.Session.t(), [{binary(), binary()}], keyword()) :: :ok
  def upload_files!(%HpcConnect.Session{} = session, files, opts \\ []) do
    mode = Keyword.get(opts, :mode, "644")

    if Keyword.get(opts, :extended_debug, false) do
      Enum.each(files, fn {local_path, remote_path} ->
        size = if File.exists?(local_path), do: File.stat!(local_path).size, else: :missing

        IO.puts(
          "[hpc-ext-debug] upload: #{Path.basename(local_path)} (#{size}B) → #{remote_path}"
        )
      end)
    end

    remote_files =
      Enum.map(files, fn {local_path, remote_path} ->
        content = local_path |> File.read!() |> String.replace("\r", "")
        {remote_path, content}
      end)

    write_files!(session, remote_files, Keyword.put(opts, :mode, mode))
  end

  @doc """
  Writes many remote text files in a minimal number of SSH commands.

  Each `{remote_path, content}` pair is rendered as complete per-file write
  steps (mkdir -p + base64 write + optional chmod) via `chunk_write_commands/3`,
  then consecutive steps are grouped into single command lines that stay below
  the OS process-spawn limit. Returns `:ok`.

  The `:connect_fun` opt (default `&HpcConnect.connect!/3`) lets callers inject
  a fake executor for offline tests.
  """
  @spec write_files!(HpcConnect.Session.t(), [{binary(), binary()}], keyword()) :: :ok
  def write_files!(%HpcConnect.Session{} = session, files, opts \\ []) do
    connect_fun = Keyword.get(opts, :connect_fun, &HpcConnect.connect!/3)
    copts = connect_opts(opts)

    files
    |> multi_write_commands(opts)
    |> Enum.each(fn cmd -> connect_fun.(session, cmd, copts) end)

    :ok
  end

  @doc """
  Pure builder of batched multi-file write commands (exposed for tests).

  `files` is a list of `{remote_path, content}`. Returns shell command strings,
  each of which performs one or more complete per-file writes (`mkdir -p` +
  base64 write + optional chmod) chained with `&&`, cut so no command line
  exceeds `@max_batch_command_size` bytes. This turns N per-file SSH calls into
  a handful of calls.
  """
  @spec multi_write_commands([{binary(), binary()}], keyword()) :: [binary()]
  def multi_write_commands(files, opts \\ []) do
    mode = Keyword.get(opts, :mode, "644")

    files
    |> Enum.flat_map(fn {remote_path, content} ->
      b64 = content |> String.replace("\r", "") |> Base.encode64()
      chunk_write_commands(b64, remote_path, mode)
    end)
    |> batch_steps(@max_batch_command_size)
    |> Enum.map(&Enum.join(&1, " && "))
  end

  # Greedy grouping of complete write steps so the joined command stays under
  # the byte budget (keeps each ssh command line below the Windows spawn limit
  # of ~32 767 chars). A single oversized step (large file) gets its own batch.
  defp batch_steps(steps, budget) do
    steps
    |> Enum.reduce({[], [], 0}, fn step, {batches, current, size} ->
      step_size = byte_size(step) + 4

      if current != [] and size + step_size > budget do
        {[Enum.reverse(current) | batches], [step], step_size}
      else
        {batches, [step | current], size + step_size}
      end
    end)
    |> case do
      {batches, [], _} -> Enum.reverse(batches)
      {batches, current, _} -> Enum.reverse([Enum.reverse(current) | batches])
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
    <<head::binary-size(^size), rest::binary>> = b64
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
