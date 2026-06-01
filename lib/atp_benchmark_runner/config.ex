defmodule AtpBenchmarkRunner.Config do
  @moduledoc """
  Environment-backed configuration helpers for local scripts and Livebook.

  The project intentionally keeps paths configurable through `.env` so the same
  notebook can run on Windows, Linux, or a hosted Livebook server without hard
  coding machine-local directories in benchmark cells.
  """

  alias AtpBenchmarkRunner.Store

  @env_file_var "ATP_BENCHMARK_RUNNER_ENV_FILE"
  @tptp_dir_var "ATP_BENCHMARK_RUNNER_TPTP_DIR"

  @doc """
  Loads configuration values from the configured `.env` file.
  """
  @spec env(keyword()) :: map()
  def env(opts \\ []) do
    opts
    |> env_file()
    |> load_env_file()
  end

  @doc """
  Returns a configuration value from OS env first, then the `.env` file.
  """
  @spec get(binary(), keyword()) :: binary() | nil
  def get(key, opts \\ []) when is_binary(key) do
    System.get_env(key) || Map.get(env(opts), key)
  end

  @doc """
  Returns the local TPTP root directory.
  """
  @spec tptp_dir(keyword()) :: binary()
  def tptp_dir(opts \\ []) do
    opts
    |> option_value([:tptp_dir, :root_dir])
    |> first_present(get(@tptp_dir_var, opts))
    |> first_present(get("TPTP_DIR", opts))
    |> first_present(Application.get_env(:atp_benchmark_runner, :tptp_dir))
    |> first_present(Path.join([Store.default_dir(), "tptp"]))
    |> expand_path()
  end

  @doc """
  Expands `~` and relative paths in a cross-platform way.
  """
  @spec expand_path(binary() | nil) :: binary() | nil
  def expand_path(nil), do: nil

  def expand_path("~" <> rest) do
    System.user_home()
    |> case do
      nil -> "~" <> rest
      home -> Path.expand(home <> rest)
    end
  end

  def expand_path(path) when is_binary(path), do: Path.expand(path)

  defp env_file(opts) do
    Keyword.get(opts, :env_file, System.get_env(@env_file_var) || ".env")
  end

  defp load_env_file(false), do: %{}
  defp load_env_file(nil), do: %{}
  defp load_env_file(path) when is_binary(path), do: HpcConnect.load_env_file(path)

  defp option_value(opts, keys) do
    Enum.find_value(keys, &Keyword.get(opts, &1))
  end

  defp first_present(nil, candidate), do: candidate
  defp first_present("", candidate), do: candidate
  defp first_present(value, _candidate), do: value
end
