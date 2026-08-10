defmodule AtpBenchmarkRunner.Config do
  @moduledoc """
  Environment-backed config via `.env`, env vars, or options.

  Keeps paths portable across Windows, Linux and Livebook.
  """

  alias AtpBenchmarkRunner.Store

  @env_file_var "ATP_BENCHMARK_RUNNER_ENV_FILE"
  @tptp_dir_var "TPTP_ROOT"
  @store_dir_var "ATP_BENCHMARK_RUNNER_STORE_DIR"
  @cache_dir_var "ATP_BENCHMARK_RUNNER_CACHE_DIR"
  @smt_tmp_dir_var "ATP_BENCHMARK_RUNNER_SMT_TMP_DIR"
  @thf_tmp_dir_var "ATP_BENCHMARK_RUNNER_THF_TMP_DIR"
  @bundled_examples_dir_var "ATP_BENCHMARK_RUNNER_BUNDLED_EXAMPLES_DIR"
  @user_examples_dir_var "ATP_BENCHMARK_RUNNER_USER_EXAMPLES_DIR"
  @single_download_dir_var "ATP_BENCHMARK_RUNNER_SINGLE_DOWNLOAD_DIR"

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
    |> first_present(Path.expand("./tmp/tptp"))
    |> expand_path()
  end

  @doc """
  Returns the local store/artifact directory for run manifests, results, and reports.

  Configure via `ATP_BENCHMARK_RUNNER_STORE_DIR` env var, `ATP_BENCHMARK_RUNNER_CACHE_DIR`
  (fallback), `:store_dir` application env, or the `:dir` option.
  """
  @spec store_dir(keyword()) :: binary()
  def store_dir(opts \\ []) do
    opts
    |> option_value([:dir, :store_dir])
    |> first_present(get(@store_dir_var, opts))
    |> first_present(get(@cache_dir_var, opts))
    |> first_present(Application.get_env(:atp_benchmark_runner, :store_dir))
    |> first_present(Store.default_dir())
    |> expand_path()
  end

  @doc """
  Returns the temporary directory used for TPTP-to-SMT converted files.

  Configure via `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` env var or the `:smt_tmp_dir` option.
  Falls back to `./tmp/smt_converted`.  Set `ATP_BENCHMARK_RUNNER_SMT_TMP_DIR` to override.
  """
  @spec smt_tmp_dir(keyword()) :: binary()
  def smt_tmp_dir(opts \\ []) do
    opts
    |> option_value([:smt_tmp_dir])
    |> first_present(get(@smt_tmp_dir_var, opts))
    |> first_present(Path.expand("./tmp/smt_converted"))
    |> expand_path()
  end

  @doc """
  Returns the temporary directory used for TPTP-to-THF converted files.

  Configure via `ATP_BENCHMARK_RUNNER_THF_TMP_DIR` env var or the `:thf_tmp_dir` option.
  Falls back to `./tmp/thf_converted`.  Set `ATP_BENCHMARK_RUNNER_THF_TMP_DIR` to override.
  """
  @spec thf_tmp_dir(keyword()) :: binary()
  def thf_tmp_dir(opts \\ []) do
    opts
    |> option_value([:thf_tmp_dir])
    |> first_present(get(@thf_tmp_dir_var, opts))
    |> first_present(Path.expand("./tmp/thf_converted"))
    |> expand_path()
  end

  @doc """
  Returns the directory where bundled TPTP examples are copied for fast local access.

  Auto-populated on first use from `priv/tptp_examples/`, then checked before
  the file index to avoid slow `:code.priv_dir/1` or stale JSON-cache lookups.

  Configure via `ATP_BENCHMARK_RUNNER_BUNDLED_EXAMPLES_DIR` env var or the
  `:bundled_dir` option. Falls back to `./tmp/tptp_examples`.
  """
  @spec bundled_examples_dir(keyword()) :: binary()
  def bundled_examples_dir(opts \\ []) do
    opts
    |> option_value([:bundled_examples_dir, :bundled_dir])
    |> first_present(get(@bundled_examples_dir_var, opts))
    |> first_present(Path.expand("./tmp/tptp_examples"))
    |> expand_path()
  end

  @doc """
  Returns the directory where users can place their own TPTP problem files.

  This dir is checked first (before bundled examples or the official TPTP
  archive) when resolving problem names. Files here take priority over
  same-named files in any other location. Users simply drop `.p` / `.ax`
  files into this directory.

  Configure via `ATP_BENCHMARK_RUNNER_USER_EXAMPLES_DIR` env var or the
  `:user_dir` option. Defaults to `<tptp_dir>/user_examples`.
  """
  @spec user_examples_dir(keyword()) :: binary()
  def user_examples_dir(opts \\ []) do
    opts
    |> option_value([:user_examples_dir, :user_dir])
    |> first_present(get(@user_examples_dir_var, opts))
    |> first_present(Path.join(tptp_dir(opts), "user_examples"))
    |> expand_path()
  end

  @doc """
  Returns the base directory under which individually downloaded TPTP problems
  are stored.

  To make downloaded single problems behave exactly like files from an unpacked
  official archive, files are written in the archive layout below this base:

    * `<base>/Problems/<DOMAIN>/<NAME>.p` for problems
    * `<base>/Axioms/<DOMAIN>/<NAME>.ax` for axioms

  Defaults to the TPTP root (`tptp_dir/1`), so downloads land directly at the
  archive-consistent paths (e.g. `<tptp_root>/Problems/GRP/GRP001-1.p`) and are
  picked up by the index, name resolution, and HPC sync without any extra steps.

  Configure via `ATP_BENCHMARK_RUNNER_SINGLE_DOWNLOAD_DIR` env var or the
  `:single_download_dir` option to redirect them elsewhere.
  """
  @spec single_download_dir(keyword()) :: binary()
  def single_download_dir(opts \\ []) do
    opts
    |> option_value([:single_download_dir])
    |> first_present(get(@single_download_dir_var, opts))
    |> first_present(tptp_dir(opts))
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
