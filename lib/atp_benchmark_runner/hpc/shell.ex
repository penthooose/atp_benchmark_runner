defmodule AtpBenchmarkRunner.HPC.Shell do
  @moduledoc false

  @doc """
  Single-quotes a value for POSIX shell use on the remote HPC side.
  """
  @spec quote(binary() | atom() | number()) :: binary()
  def quote(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end
