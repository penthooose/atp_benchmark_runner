defmodule AtpBenchmarkRunner.Visualize.Proof do
  @moduledoc """
  Parses SZS proof/refutation blocks into a dependency graph that can be
  rendered as a Mermaid flowchart.

  Machine-readable TPTP clause refutations — the `fof`/`cnf`/`tff`/`thf` steps
  with `inference(...)` annotations emitted by E, Vampire and similar provers —
  are parsed into `%{steps, edges, root}`. Proof formats that do not follow
  that shape (e.g. prose or LaTeX-style output) are reported as `{:error, _}`
  so `Visualize.proof/2` can degrade gracefully to a pipeline diagram.
  """

  alias AtpBenchmarkRunner.Result

  @typedoc "A single parsed proof step."
  @type step :: %{
          name: binary(),
          role: binary(),
          clause: binary(),
          deps: [binary()]
        }

  @typedoc "A dependency graph over proof steps."
  @type graph :: %{steps: [step()], edges: [{binary(), binary()}], root: binary() | nil}

  # `fof(name, role, <formula + annotations>)`. Name and role cannot contain
  # parens; the formula/annotation tail is captured verbatim.
  @step_re ~r/^(fof|cnf|tff|thf)\(\s*([^,()]+?)\s*,\s*([^,()]+?)\s*,(.*)$/

  @doc """
  Parses the SZS output block of a result into a dependency graph.

  Returns `{:ok, graph}` when at least one TPTP clause step is found,
  `{:error, reason}` otherwise.
  """
  @spec parse(Result.t()) :: {:ok, graph()} | {:error, binary()}
  def parse(%Result{} = result) do
    case Result.extract_proof(result) do
      nil ->
        {:error, "no SZS proof block in raw output"}

      block ->
        case parse_block(block) do
          %{steps: []} -> {:error, "proof block has no parseable TPTP clause steps"}
          graph -> {:ok, graph}
        end
    end
  end

  @doc """
  Parses a raw proof block string into a dependency graph.
  """
  @spec parse_block(binary()) :: graph()
  def parse_block(block) when is_binary(block) do
    steps =
      block
      |> String.split("\n")
      |> Enum.map(&parse_step/1)
      |> Enum.reject(&is_nil/1)

    names = MapSet.new(steps, & &1.name)

    steps =
      Enum.map(steps, fn step ->
        %{step | deps: deps_for(step.name, step.line, names)}
      end)

    %{steps: steps, edges: edges(steps), root: find_root(steps)}
  end

  defp parse_step(line) do
    case Regex.run(@step_re, String.trim(line)) do
      [_, _kind, name, role, rest] ->
        %{name: name, role: role, clause: clause_snippet(rest), line: line, deps: []}

      _ ->
        nil
    end
  end

  # The clause is everything before the first `inference(...)`/`file(...)`
  # annotation. Keep it short — Mermaid labels should stay readable.
  defp clause_snippet(rest) do
    rest
    |> String.split(~r/,\s*(?:inference|file)\(/, parts: 2)
    |> hd()
    |> String.trim_trailing(",")
    |> String.trim()
    |> String.slice(0, 60)
  end

  # Dependencies are references to other step names inside the line. Use word
  # boundaries so a step named `a` does not match `a1`.
  defp deps_for(name, line, names) do
    names
    |> MapSet.to_list()
    |> Enum.reject(&(&1 == name))
    |> Enum.filter(&Regex.match?(~r/\b#{Regex.escape(&1)}\b/, line))
  end

  # The refutation target is the step whose clause is `$false`/`$true`;
  # fall back to the last step (usually the conclusion).
  defp find_root([]), do: nil

  defp find_root(steps) do
    case Enum.find(steps, &String.contains?(&1.clause, "$false")) do
      nil ->
        case Enum.find(steps, &String.contains?(&1.clause, "$true")) do
          nil -> steps |> List.last() |> Map.get(:name)
          step -> step.name
        end

      step ->
        step.name
    end
  end

  defp edges(steps) do
    for step <- steps, dep <- step.deps, do: {dep, step.name}
  end
end
