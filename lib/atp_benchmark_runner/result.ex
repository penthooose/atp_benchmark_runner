defmodule AtpBenchmarkRunner.Result do
  @moduledoc """
  Parsed result of running one prover on one benchmark problem.
  """

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Provers

  @solved_statuses MapSet.new(~w(
    Theorem Unsatisfiable Satisfiable CounterSatisfiable ContradictoryAxioms
    CounterTheorem Equivalent NotEquivalent
  ))

  @enforce_keys [:problem_id, :prover]
  defstruct [
    :run_id,
    :problem_id,
    :problem_name,
    :prover,
    :szs_status,
    :exit_status,
    :wall_time_ms,
    :memory_kb,
    :collected_at,
    :output_path,
    :raw_output,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          run_id: binary() | nil,
          problem_id: binary(),
          problem_name: binary() | nil,
          prover: atom(),
          szs_status: binary() | nil,
          exit_status: integer() | nil,
          wall_time_ms: non_neg_integer() | nil,
          memory_kb: non_neg_integer() | nil,
          collected_at: binary() | nil,
          output_path: binary() | nil,
          raw_output: binary() | nil,
          metadata: map()
        }

  @doc """
  Builds a result from attrs.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)

    %__MODULE__{
      run_id: Map.get(attrs, :run_id),
      problem_id: to_string(Map.fetch!(attrs, :problem_id)),
      problem_name: Map.get(attrs, :problem_name),
      prover: normalize_prover(Map.fetch!(attrs, :prover)),
      szs_status: Map.get(attrs, :szs_status),
      exit_status: Map.get(attrs, :exit_status),
      wall_time_ms: Map.get(attrs, :wall_time_ms),
      memory_kb: Map.get(attrs, :memory_kb),
      collected_at: Map.get(attrs, :collected_at),
      output_path: Map.get(attrs, :output_path),
      raw_output: Map.get(attrs, :raw_output),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Parses a prover stdout/stderr blob into a result.

  The prover may be given as a `Prover` struct (preferred), or as a name; the
  declared `parser` (from the prover spec) drives status extraction, so provers
  that emit bare `sat`/`unsat`/`unknown` answers (e.g. cvc5 in SMT-LIB mode)
  are handled without special-casing. An explicit `:parser` opt overrides.
  """
  @spec from_output(Prover.t() | binary() | atom(), binary(), binary(), keyword()) :: t()
  def from_output(prover, problem_id, output, attrs \\ []) do
    parser = Keyword.get(attrs, :parser, parser_for(prover))

    attrs
    |> Keyword.put(:prover, prover_name(prover))
    |> Keyword.put(:problem_id, problem_id)
    |> Keyword.put_new(:szs_status, parse_for(parser, output))
    |> Keyword.put_new(:raw_output, output)
    |> refine_timeout_to_gaveup()
    |> add_unsupported_reason()
    |> new()
  end

  defp prover_name(%Prover{name: name}), do: name
  defp prover_name(other), do: other

  defp parser_for(%Prover{parser: parser}), do: parser
  defp parser_for(name), do: Provers.parser_for(name)

  @doc """
  Extracts an SZS status from output using a prover's declared parser.

    * `:szs` — standard SZS status extraction (default)
    * `:smt_bare` — bare SMT-LIB `sat`/`unsat`/`unknown` answer, falling back
      to SZS extraction (cvc5 in SMT-LIB mode)
    * `{:custom, Mod}` — `Mod.parse/1`, falling back to SZS extraction
  """
  @spec parse_for(atom() | tuple(), binary()) :: binary() | nil
  def parse_for(parser, output) when is_binary(output) do
    case parser do
      :szs ->
        parse_szs_status(output)

      :smt_bare ->
        plain_answer(output) || parse_szs_status(output)

      {:custom, mod} when is_atom(mod) ->
        mod.parse(output) || parse_szs_status(output)

      _ ->
        parse_szs_status(output)
    end
  end

  # Add a metadata reason when the status is UnsupportedLogic, so the
  # report can show why the problem was skipped.
  defp add_unsupported_reason(attrs) do
    status = Keyword.get(attrs, :szs_status)

    if status == "UnsupportedLogic" do
      metadata = Keyword.get(attrs, :metadata, %{})

      metadata =
        Map.put_new(
          metadata,
          :reason,
          "Prover produced no output — the problem type is not solvable " <>
            "by this prover (e.g., no conjecture for a refutation prover)."
        )

      Keyword.put(attrs, :metadata, metadata)
    else
      attrs
    end
  end

  # When the prover process exited normally (exit code 0) but the SZS status
  # is "Timeout", it means the prover ran through all its strategies without
  # finding a proof. This is not a real timeout — the problem type is not
  # solvable by this prover (e.g., no conjecture for a refutation prover).
  # Report as UnsupportedLogic instead of misleading "Timeout" or "GaveUp".
  defp refine_timeout_to_gaveup(attrs) do
    status = Keyword.get(attrs, :szs_status)
    exit_status = Keyword.get(attrs, :exit_status)

    if status == "Timeout" and exit_status == 0 do
      metadata = Keyword.get(attrs, :metadata, %{})

      metadata =
        Map.put_new(
          metadata,
          :reason,
          "Prover exited normally with status \"Timeout\" in output — " <>
            "the problem type is not solvable by this prover " <>
            "(e.g., no conjecture for a refutation prover)."
        )

      attrs
      |> Keyword.put(:szs_status, "UnsupportedLogic")
      |> Keyword.put(:metadata, metadata)
    else
      attrs
    end
  end

  @doc """
  Extracts the first SZS status from ATP output.

  Handles both `% SZS status ...` (TPTP standard, used by E, Vampire, Leo3, cvc5)
  and `# SZS status ...` (used by Zipperposition and some OCaml-based provers).
  Also infers a status from common error patterns when no explicit SZS line
  is present, and overrides `GaveUp` to `Satisfiable` when the prover reports
  "no conjecture found" (refutation prover on a satisfiability-only problem).
  """
  @spec parse_szs_status(binary()) :: binary() | nil
  def parse_szs_status(output) when is_binary(output) do
    case Regex.run(
           ~r/(?:^|\n)\s*[%#]?\s*SZS\s+status\s+([A-Za-z][A-Za-z0-9_]*)/i,
           output,
           capture: :all_but_first
         ) do
      [status] -> refine_explicit_status(status, output)
      _ -> infer_error_status(output)
    end
  end

  # Prefer a genuine plain-language answer over a fallback-appended status.
  # The HPC job scripts append `% SZS status GaveUp` (or Timeout) when a prover
  # emits no explicit SZS line; SMT-LIB-style provers such as cvc5 print a bare
  # `sat`/`unsat`/`unknown` answer that must win over that appended line, and
  # the AISE tableaux solver reports `status: UNSAT` / `status: SAT`.
  defp refine_explicit_status(status, output) when status in ["GaveUp", "Timeout"] do
    case plain_answer(output) do
      nil -> refine_status(status, output)
      answer -> answer
    end
  end

  defp refine_explicit_status(status, output), do: refine_status(status, output)

  # Map a bare SMT-LIB / tableaux answer token to an SZS status, or nil.
  # `unsatisfiable` contains `satisfiable`, so the unsat branch must come first.
  defp plain_answer(output) do
    lower = String.downcase(output)

    cond do
      Regex.match?(~r/(^|\n)\s*unsat\s*($|\n)/, lower) or
        Regex.match?(~r/status:[ \t]*unsat\b/, lower) or
          Regex.match?(~r/(^|[^a-z])unsatisfiable([^a-z]|$)/, lower) ->
        "Unsatisfiable"

      Regex.match?(~r/(^|\n)\s*sat\s*($|\n)/, lower) or
        Regex.match?(~r/status:[ \t]*sat\b/, lower) or
          Regex.match?(~r/(^|[^a-z])satisfiable([^a-z]|$)/, lower) ->
        "Satisfiable"

      Regex.match?(~r/(^|\n)\s*unknown\s*($|\n)/, lower) ->
        "Unknown"

      true ->
        nil
    end
  end

  # Refine an explicitly matched SZS status based on surrounding output context.
  # This handles cases where the prover's raw status is misleading.
  defp refine_status("GaveUp", output) do
    lower = String.downcase(output)

    if String.contains?(lower, "no conjecture found") do
      # Refutation prover (Leo3) GaveUp on a satisfiability-only problem
      # with no conjecture. The axioms are consistent → Satisfiable.
      "Satisfiable"
    else
      "GaveUp"
    end
  end

  defp refine_status(status, _output), do: status

  # Infer SZS status from common crash/error patterns when no explicit SZS line.
  # Uses case-insensitive matching via String.downcase/1.
  defp infer_error_status(output) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" or trimmed == "\n" ->
        "UnsupportedLogic"

      true ->
        lower = String.downcase(output)

        cond do
          String.contains?(lower, "typeerror") or
            String.contains?(lower, "type error") or
            String.contains?(lower, "ill-typed") or
              String.contains?(lower, "type check") ->
            "TypeError"

          String.contains?(lower, "unification error") or
              String.contains?(lower, "unification failure") ->
            "InputError"

          String.contains?(lower, "inputerror") or
            String.contains?(lower, "parse error") or
            String.contains?(lower, "closing bracket") or
              String.contains?(lower, "expected but") ->
            "InputError"

          String.contains?(lower, "not found") or
              String.contains?(lower, "does not exist") ->
            "InputError"

          # No crash pattern: fall back to a bare sat/unsat/unknown answer
          # (cvc5 in SMT-LIB mode, AISE tableaux report wording, etc.).
          true ->
            plain_answer(output)
        end
    end
  end

  @doc """
  Returns true for statuses that count as a successful solve in TPTP reporting.
  """
  @spec solved?(t() | binary() | nil) :: boolean()
  def solved?(%__MODULE__{szs_status: status}), do: solved?(status)
  def solved?(status) when is_binary(status), do: MapSet.member?(@solved_statuses, status)
  def solved?(_), do: false

  @doc """
  Extracts the SZS proof/refutation section from the raw prover output.

  Most provers delimit their proof output between `% SZS output start <kind>`
  and `% SZS output end <kind>` (or `# SZS output start` / `# SZS output end`
  for Zipperposition). Returns the extracted block as a string, or `nil` if
  no proof section is found.

  ## Examples

      iex> output = "% SZS output start Proof for GRP001-0\\nfof(f1, axiom, a).\\n% SZS output end Proof for GRP001-0"
      iex> AtpBenchmarkRunner.Result.extract_proof(output)
      "fof(f1, axiom, a)."

      iex> output = "# SZS output start Refutation\\n* ⊥ by simp\\n# SZS output end Refutation"
      iex> AtpBenchmarkRunner.Result.extract_proof(output)
      "* ⊥ by simp"
  """
  @spec extract_proof(t() | binary() | nil) :: binary() | nil
  def extract_proof(%__MODULE__{raw_output: raw}) when is_binary(raw), do: extract_proof(raw)
  def extract_proof(%__MODULE__{}), do: nil
  def extract_proof(nil), do: nil

  def extract_proof(output) when is_binary(output) do
    case Regex.run(
           ~r/(?:^|\n)\s*[%#]\s*SZS\s+output\s+start\s+[^\n]*\n(.*?)\n\s*[%#]\s*SZS\s+output\s+end/s,
           output,
           capture: :all_but_first
         ) do
      [proof_body] -> String.trim(proof_body)
      _ -> nil
    end
  end

  @doc """
  Returns a compact human-readable summary of a prover result.

  Shows prover, problem, status, and wall time — no proof details.
  For full output with proof snippets, use `explain_full/1`.

  ## Examples

      iex> result = %AtpBenchmarkRunner.Result{prover: :eprover, problem_id: "GRP001-0", szs_status: "Theorem", wall_time_ms: 812}
      iex> AtpBenchmarkRunner.Result.explain(result)
      "[eprover] GRP001-0 — ✅ Solved (Theorem)\\n  Wall time: 812 ms\\n"
  """
  @spec explain(t()) :: binary()
  def explain(%__MODULE__{} = result) do
    status = result.szs_status || "Unknown"
    solved_label = if solved?(result), do: "✅ Solved", else: "❌ Failed"
    time_str = format_time(result.wall_time_ms)

    """
    [#{result.prover}] #{result.problem_id} — #{solved_label} (#{status})
      Wall time: #{time_str}
    """
  end

  @doc """
  Returns a detailed human-readable summary including a proof snippet
  when the result was solved and a proof section is found.

  Accepts a single result or a list of results. When given a list,
  returns a newline-joined string for all results.
  """
  @spec explain_full(t() | [t()]) :: binary()
  def explain_full(results) when is_list(results) do
    results |> Enum.map(&explain_full/1) |> Enum.join("\n")
  end

  def explain_full(%__MODULE__{} = result) do
    status = result.szs_status || "Unknown"
    solved_label = if solved?(result), do: "✅ Solved", else: "❌ Failed"
    time_str = format_time(result.wall_time_ms)
    proof = extract_proof(result)

    summary = """
    [#{result.prover}] #{result.problem_id} — #{solved_label} (#{status})
      Wall time: #{time_str}
    """

    if proof && solved?(result) do
      proof_snippet = truncate_proof(proof, 30)

      summary <>
        """
          Proof (#{line_count(proof)} lines):
        #{indent(proof_snippet, 4)}
        """
    else
      summary
    end
  end

  @doc """
  Finds a result by prover and problem ID, then prints the proof section
  (or a diagnostic) directly to stdout. Returns `:ok`.

  ## Examples

      iex> AtpBenchmarkRunner.Result.show_proof(results, :vampire, "SMT001+0")
      Full proof for SMT001+0 / vampire:
      ...
  """
  @spec show_proof([t()] | t(), atom() | binary(), binary()) :: :ok
  def show_proof(results, prover, problem_id) when is_list(results) do
    result = Enum.find(results, fn r -> r.prover == prover and r.problem_id == problem_id end)
    show_proof(result, prover, problem_id)
  end

  def show_proof(nil, prover, problem_id) do
    IO.puts("Result not found for #{problem_id} / #{prover}")
    :ok
  end

  def show_proof(%__MODULE__{} = result, _prover, _problem_id) do
    prover = result.prover
    problem_id = result.problem_id

    if result.raw_output do
      proof = extract_proof(result)

      cond do
        proof ->
          IO.puts("Full proof for #{problem_id} / #{prover}:")
          IO.puts("")
          IO.puts("```")
          IO.puts(proof)
          IO.puts("```")

        solved?(result) ->
          IO.puts(
            "#{problem_id} / #{prover} solved (#{result.szs_status}), but no proof section found."
          )

          IO.puts("Raw output first 500 chars:")
          IO.puts(String.slice(result.raw_output, 0, 500))

        true ->
          IO.puts("#{problem_id} / #{prover}: #{result.szs_status || "?"} — no proof available.")
          IO.puts("Raw output first 500 chars:")
          IO.puts(String.slice(result.raw_output, 0, 500))
      end
    else
      IO.puts(
        "#{problem_id} / #{prover}: no raw output stored (rerun with include_raw_output: true)"
      )
    end

    :ok
  end

  defp format_time(nil), do: "N/A"
  defp format_time(ms) when ms < 1000, do: "#{ms} ms"
  defp format_time(ms), do: "#{Float.round(ms / 1000, 2)} s"

  defp truncate_proof(proof, max_lines) do
    lines = String.split(proof, "\n")

    if length(lines) > max_lines do
      taken = Enum.take(lines, max_lines)
      Enum.join(taken, "\n") <> "\n  ... (#{length(lines) - max_lines} more lines)"
    else
      proof
    end
  end

  defp line_count(proof), do: length(String.split(proof, "\n"))

  defp indent(text, spaces) do
    text
    |> String.split("\n")
    |> Enum.map(&(String.duplicate(" ", spaces) <> &1))
    |> Enum.join("\n")
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      run_id: result.run_id,
      problem_id: result.problem_id,
      problem_name: result.problem_name,
      prover: result.prover,
      szs_status: result.szs_status,
      exit_status: result.exit_status,
      wall_time_ms: result.wall_time_ms,
      memory_kb: result.memory_kb,
      collected_at: result.collected_at,
      output_path: result.output_path,
      raw_output: result.raw_output,
      metadata: result.metadata
    }
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(map), do: new(map)

  defp normalize_prover(prover) when is_atom(prover), do: prover

  defp normalize_prover(prover) when is_binary(prover) do
    case AtpBenchmarkRunner.Provers.fetch(prover) do
      {:ok, known} -> known.name
      :error -> String.to_existing_atom(prover)
    end
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> put_known_key(acc, key, value)
    end)
  end

  defp put_known_key(acc, key, value) do
    case key do
      "run_id" -> Map.put(acc, :run_id, value)
      "problem_id" -> Map.put(acc, :problem_id, value)
      "problem_name" -> Map.put(acc, :problem_name, value)
      "prover" -> Map.put(acc, :prover, value)
      "szs_status" -> Map.put(acc, :szs_status, value)
      "exit_status" -> Map.put(acc, :exit_status, value)
      "wall_time_ms" -> Map.put(acc, :wall_time_ms, value)
      "memory_kb" -> Map.put(acc, :memory_kb, value)
      "collected_at" -> Map.put(acc, :collected_at, value)
      "output_path" -> Map.put(acc, :output_path, value)
      "raw_output" -> Map.put(acc, :raw_output, value)
      "metadata" -> Map.put(acc, :metadata, value)
      _unknown -> acc
    end
  end
end
