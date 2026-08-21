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
end
