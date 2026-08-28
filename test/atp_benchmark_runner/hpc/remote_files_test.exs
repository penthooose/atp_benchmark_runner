defmodule AtpBenchmarkRunner.HPC.RemoteFilesTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.HPC.RemoteFiles

  describe "chunk_write_commands/3" do
    test "small payload yields a single write chunk plus chmod" do
      b64 = Base.encode64("small content")

      commands = RemoteFiles.chunk_write_commands(b64, "/home/user/tasks.txt", "644")

      assert length(commands) == 2
      assert hd(commands) =~ "mkdir -p '/home/user'"
      assert hd(commands) =~ "printf %s"
      assert hd(commands) =~ "base64 -d > '/home/user/tasks.txt'"
      assert Enum.at(commands, 1) == "chmod 644 '/home/user/tasks.txt'"
    end

    test "no chmod when mode is nil" do
      b64 = Base.encode64("content")
      commands = RemoteFiles.chunk_write_commands(b64, "/a/b.txt", nil)
      assert length(commands) == 1
      refute Enum.any?(commands, &String.starts_with?(&1, "chmod"))
    end

    test "large payload is split into chunks, first truncates rest append" do
      # ~40 KB of content → well over the 16 KB base64 chunk budget.
      content = String.duplicate("The quick brown fox jumps over the lazy dog. ", 800)
      b64 = content |> String.replace("\r", "") |> Base.encode64()

      commands = RemoteFiles.chunk_write_commands(b64, "/home/user/big/tasks.txt", "644")

      # >= 2 write chunks + 1 chmod
      write_cmds = Enum.drop(commands, -1)
      assert length(write_cmds) >= 2

      # First chunk truncates, the rest append
      assert hd(write_cmds) =~ "base64 -d > '/home/user/big/tasks.txt'"

      write_cmds
      |> Enum.drop(1)
      |> Enum.each(fn cmd ->
        assert cmd =~ "base64 -d >> '/home/user/big/tasks.txt'"
      end)

      # Every generated command line stays far below the ~32 767-char limit.
      Enum.each(commands, fn cmd -> assert byte_size(cmd) < 20_000 end)
    end

    test "chunks reassemble to the original content" do
      content = String.duplicate("chunked base64 round-trip check. ", 500)
      b64 = content |> String.replace("\r", "") |> Base.encode64()

      commands = RemoteFiles.chunk_write_commands(b64, "/x/y.txt", nil)

      reassembled =
        commands
        |> Enum.map(fn cmd ->
          # extract the base64 token between `printf %s '` and `'`
          Regex.run(~r/printf %s '([^']+)'/, cmd, capture: :all_but_first)
          |> List.first()
        end)
        |> Enum.join()
        |> Base.decode64!()

      assert reassembled == content
    end
  end

  describe "multi_write_commands/2" do
    test "batches multiple small files into a single command" do
      files = [
        {"/home/user/a.p", "fof(a, axiom, p)."},
        {"/home/user/b.p", "fof(b, axiom, q)."},
        {"/home/user/c.p", "fof(c, axiom, r)."}
      ]

      commands = RemoteFiles.multi_write_commands(files)

      # 3 files → 1 write step + 1 chmod per file → 6 steps, joined into 1 command
      assert length(commands) == 1

      write_count =
        commands
        |> Enum.map(fn cmd ->
          Regex.scan(~r{base64 -d > '/home/user/(a|b|c)\.p'}, cmd) |> length()
        end)
        |> Enum.sum()

      assert write_count == 3
      assert commands |> hd() =~ "mkdir -p '/home/user'"
      # CRLF normalization happens per file
      refute commands |> hd() =~ "\r"
    end

    test "each file still gets its own chmod when mode is set" do
      files = [
        {"/r/a.p", "fof(a, axiom, p)."},
        {"/r/b.p", "fof(b, axiom, q)."}
      ]

      commands = RemoteFiles.multi_write_commands(files, mode: "644")
      assert length(commands) == 1
      assert commands |> hd() =~ "chmod 644 '/r/a.p'"
      assert commands |> hd() =~ "chmod 644 '/r/b.p'"
    end

    test "large total payload is split into several commands" do
      files =
        Enum.map(1..20, fn i ->
          {"/home/user/f#{i}.p", String.duplicate("fof(p#{i}, axiom, big_content). ", 2000)}
        end)

      commands = RemoteFiles.multi_write_commands(files)

      assert length(commands) >= 2

      # Every generated command line stays far below the ~32 767-char limit.
      Enum.each(commands, fn cmd -> assert byte_size(cmd) < 30_000 end)

      # All 20 files are present across the batches
      total_writes =
        commands
        |> Enum.map(fn cmd ->
          Regex.scan(~r{base64 -d > '/home/user/f\d+\.p'}, cmd) |> length()
        end)
        |> Enum.sum()

      assert total_writes == 20
    end

    test "batch commands reassemble to the original file contents" do
      files = [
        {"/home/user/one.p", "content one"},
        {"/home/user/two.p", String.duplicate("content two ", 3000)},
        {"/home/user/three.p", "content three"}
      ]

      commands = RemoteFiles.multi_write_commands(files)

      # Extract every base64 payload and its target path, reassemble per path
      reassembled =
        commands
        |> Enum.flat_map(fn cmd ->
          Regex.scan(~r/printf %s '([^']+)' \| base64 -d >>? '([^']+)'/, cmd,
            capture: :all_but_first
          )
        end)
        |> Enum.map(fn [b64, path] -> {path, b64} end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {path, b64s} -> {path, b64s |> Enum.join() |> Base.decode64!()} end)

      assert reassembled["/home/user/one.p"] == "content one"
      assert reassembled["/home/user/two.p"] == String.duplicate("content two ", 3000)
      assert reassembled["/home/user/three.p"] == "content three"
    end
  end

  describe "write_files!/3 and upload_files!/3 (offline via injected connect_fun)" do
    test "write_files! sends each batch command through connect_fun" do
      session = HpcConnect.Session.local(env_file: false)

      result =
        RemoteFiles.write_files!(
          session,
          [{"/remote/tasks.txt", "task one"}],
          connect_fun: fn _session, cmd, _opts ->
            send(self(), {:cmd, cmd})
            :ok
          end
        )

      assert result == :ok
      assert_received {:cmd, cmd}
      assert cmd =~ "mkdir -p '/remote'"
      assert cmd =~ "base64 -d > '/remote/tasks.txt'"
    end

    test "upload_files! reads local files and writes them remotely (batched)" do
      tmp = Path.join(System.tmp_dir!(), "rf_up_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      local_a = Path.join(tmp, "a.p")
      local_b = Path.join(tmp, "b.p")
      File.write!(local_a, "fof(a, axiom, p).\r\n")
      File.write!(local_b, String.duplicate("fof(b, axiom, q). ", 2000))

      session = HpcConnect.Session.local(env_file: false)

      captured =
        RemoteFiles.upload_files!(
          session,
          [{local_a, "/remote/a.p"}, {local_b, "/remote/b.p"}],
          connect_fun: fn _session, cmd, _opts ->
            send(self(), {:cmd, cmd})
            :ok
          end
        )

      assert captured == :ok

      received =
        Stream.repeatedly(fn ->
          receive do
            {:cmd, cmd} -> {:ok, cmd}
          after
            0 -> :done
          end
        end)
        |> Enum.take_while(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, cmd} -> cmd end)

      # Both files should be written (2 write steps + 2 chmods), all in one batch.
      assert length(received) >= 1
      joined = Enum.join(received, " ")

      assert joined =~ "a.p"
      assert joined =~ "b.p"
      # CRLF normalized: no \r must reach the remote write
      refute joined =~ "\r"
      # Every generated command stays below the OS spawn limit
      Enum.each(received, fn cmd -> assert byte_size(cmd) < 30_000 end)

      File.rm_rf!(tmp)
    end
  end

  describe "write_text!/4 with single_command (steady-shell burst reduction)" do
    test "large payload is delivered as one joined command, not N chunk calls" do
      session = HpcConnect.Session.local(env_file: false)

      # Large payload so it would normally be split across multiple calls.
      content = String.duplicate("single command write payload. ", 2000)
      b64 = content |> String.replace("\r", "") |> Base.encode64()
      assert byte_size(b64) > 16_000

      result =
        RemoteFiles.write_text!(
          session,
          "/remote/tasks.tsv",
          content,
          single_command: true,
          connect_opts: [
            run_fun: fn command, _opts ->
              send(self(), {:cmd, command})
              :ok
            end
          ]
        )

      assert result == :ok

      # Exactly one call with every chunk + chmod chained by `&&`. The remote
      # command is shell-escaped inside the ssh args, so assert on fragments.
      assert_received {:cmd, %HpcConnect.Command{args: args}}
      command = Enum.join(args, " ")
      assert command =~ "mkdir -p"
      assert command =~ "base64 -d >"
      assert command =~ "base64 -d >>"
      assert command =~ "chmod 644"
      # Multiple chunk payloads were joined into this single command.
      assert length(String.split(command, "printf %s")) >= 3

      # No second call for the same payload.
      refute_received {:cmd, _}
    end

    test "single_command still reassembles to the original content" do
      content = String.duplicate("joined reassembly check. ", 1500)
      b64 = content |> String.replace("\r", "") |> Base.encode64()
      assert byte_size(b64) > 16_000

      cmd =
        b64
        |> RemoteFiles.chunk_write_commands("/r/tasks.tsv", "644")
        |> Enum.join(" && ")

      reassembled =
        cmd
        |> then(&Regex.scan(~r/printf %s '([^']+)'/, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.join()
        |> Base.decode64!()

      assert reassembled == content
    end
  end
end
