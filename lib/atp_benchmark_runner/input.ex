defmodule AtpBenchmarkRunner.Input do
  @moduledoc """
  Generic per-prover input preparation.

  A prover's `input` field (declared in `priv/provers/<name>/prover.exs`)
  selects how a TPTP problem is fed to the prover:

    * `:tptp`  (default) — the raw TPTP `.p` file is used as-is
    * `:smt2`  — the problem is converted to SMT-LIB v2 first (e.g. cvc5)
    * `:thf`   — FOF/CNF/TFF is converted to Lash-safe THF first (e.g. lash)
    * `{:custom, Mod}` — delegate input preparation to `Mod`:
        - `Mod.local_mount(path)`        -> `{mount_dir, mount_file}`
        - `Mod.remote_input_path(path)`  -> the input path for the HPC task
        - `Mod.convert(path)`            -> `:ok` after writing a converted file

  Both the local runner and the HPC job-script/sync paths go through this
  module, so per-prover input special-casing lives in exactly one place.
  """

  alias AtpBenchmarkRunner.{Config, Problem, Prover, TPTPToSMT}
  alias AtpBenchmarkRunner.TPTP.ToTHF

  @doc """
  Returns `{mount_dir, mount_file}` for a local Docker run: which host
  directory to mount and which file inside it the prover should receive.

  Converted inputs (`:smt2`/`:thf`) are materialised in the configured temp
  dirs so the original TPTP file is never modified.
  """
  @spec local_mount(Prover.t(), binary()) :: {binary(), binary()}
  def local_mount(%Prover{} = prover, problem_path) do
    case prover.input do
      :tptp ->
        dir = problem_path |> Path.dirname() |> Path.expand()
        {dir, Path.basename(problem_path)}

      :smt2 ->
        smt = local_smt_path(problem_path)
        {Path.dirname(smt), Path.basename(smt)}

      :thf ->
        thf = ToTHF.ensure_thf(problem_path, :lash, output_dir: Config.thf_tmp_dir())
        {Path.dirname(thf), Path.basename(thf)}

      {:custom, mod} when is_atom(mod) ->
        mod.local_mount(problem_path)

      other ->
        raise ArgumentError, "unknown input mode for #{prover.name}: #{inspect(other)}"
    end
  end

  @doc """
  Returns the input path the HPC task script should execute against, after any
  needed conversion. Mirrors the path logic used during problem sync.
  """
  @spec remote_input_path(Prover.t(), binary() | Problem.t()) :: binary()
  def remote_input_path(%Prover{} = prover, problem_or_path) do
    path = problem_path(problem_or_path)

    case prover.input do
      :tptp ->
        path

      :smt2 ->
        replace_ext(path, ".smt2")

      :thf ->
        replace_ext(path, "_thf.p")

      {:custom, mod} when is_atom(mod) ->
        mod.remote_input_path(path)

      other ->
        raise ArgumentError, "unknown input mode for #{prover.name}: #{inspect(other)}"
    end
  end

  @doc """
  Pre-converts a problem for HPC sync when the prover needs it (writes the
  converted file next to the original so it is uploaded alongside). Returns
  `:ok`; no-op for `:tptp` provers.
  """
  @spec convert_problem(Prover.t(), binary() | Problem.t()) :: :ok
  def convert_problem(%Prover{} = prover, problem) do
    case prover.input do
      :tptp ->
        :ok

      :smt2 ->
        smt_path = replace_ext(problem_path(problem), ".smt2")
        File.write!(smt_path, TPTPToSMT.convert_file!(problem_path(problem)))
        :ok

      :thf ->
        _ =
          ToTHF.ensure_thf(problem_path(problem), :lash,
            output_dir: Path.dirname(problem_path(problem))
          )

        :ok

      {:custom, mod} when is_atom(mod) ->
        mod.convert(problem_path(problem))

      other ->
        raise ArgumentError, "unknown input mode for #{prover.name}: #{inspect(other)}"
    end
  end

  @doc """
  True when the prover consumes a converted input rather than raw TPTP.
  """
  @spec needs_conversion?(Prover.t()) :: boolean()
  def needs_conversion?(%Prover{input: :tptp}), do: false
  def needs_conversion?(%Prover{input: _}), do: true

  # ── internals ──────────────────────────────────────────────────────────────

  defp local_smt_path(problem_path) do
    smt_dir = Config.smt_tmp_dir()
    File.mkdir_p!(smt_dir)
    smt_name = Path.basename(problem_path, ".p") <> ".smt2"
    smt_path = Path.join(smt_dir, smt_name)
    File.write!(smt_path, TPTPToSMT.convert_file!(problem_path))
    smt_path
  end

  defp replace_ext(path, suffix) do
    cond do
      String.ends_with?(path, ".p") -> String.replace_suffix(path, ".p", suffix)
      String.ends_with?(path, ".tptp") -> String.replace_suffix(path, ".tptp", suffix)
      true -> path
    end
  end

  defp problem_path(%Problem{path: path}) when is_binary(path), do: path
  defp problem_path(%Problem{name: name}), do: name
  defp problem_path(path) when is_binary(path), do: path
end
