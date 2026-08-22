defmodule AtpBenchmarkRunner.TPTP.ToTHF do
  @moduledoc """
  Converts FOF/CNF/TFF TPTP problems to THF for Lash, a TH0 higher-order
  prover.

  Lash rejects raw FOF and, unlike most provers, requires:
    * explicit `@`-application (`(multiply @ X @ Y)`, not `multiply(X, Y)`),
    * correctly typed `$i`/`$o` declarations (functions/constants return `$i`,
      predicates return `$o`, quantified FO variables are `$i`),
    * equations parenthesized (`((l) = (r))`) because Lash binds `=` tighter
      than `@` (e.g. `identity @ X = X` is read as `identity @ (X = X)`).

  This converter reuses the tokenizer + recursive-descent parser from
  `TPTPToSMT` (`parse_string!/1`) and re-emits each parsed entry as THF with
  the rules above. Explicit `thf(NAME, type, (SYM: TYPE)).` declarations from
  already-THF problems are preserved; otherwise types are inferred from usage.

  Design: runs **outside** the container, in the Elixir runner, before the
  problem file is mounted/uploaded to Lash.
  """

  alias AtpBenchmarkRunner.TPTPToSMT

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Converts a TPTP problem string to THF. Returns converted string.
  """
  @spec convert_string(binary()) :: binary()
  def convert_string(content) when is_binary(content) do
    header = content |> String.split(~r{[\r\n]+}) |> split_header() |> elem(0)
    entries = TPTPToSMT.parse_string!(content)

    if entries == [] do
      # Parser could not handle this problem (e.g. exotic higher-order syntax).
      # Fall back to a minimal rename so we never emit an empty problem.
      legacy_fallback(content, header)
    else
      {sig, bvars} = TPTPToSMT.collect_signature!(entries)
      explicit = extract_explicit_types(content)
      types = generate_types(sig, explicit, bvars)
      formulas = Enum.map(entries, &emit_entry(&1, bvars))

      ([update_spc(header), "", types, ""] ++ formulas)
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    end
  end

  @doc """
  Converts a TPTP file to THF, returns `{output_path, content}`.
  """
  @spec convert_file(binary(), keyword()) :: {binary(), binary()}
  def convert_file(path, opts \\ []) do
    content = File.read!(path)
    converted = convert_string(content)
    out_dir = Keyword.get(opts, :output_dir, Path.dirname(path))
    base = Path.basename(path, ".p")
    out = Path.join(out_dir, "#{base}_thf.p")
    File.write!(out, converted)
    {out, converted}
  end

  @doc """
  Returns the path to a THF-converted problem for Lash. Always converts —
  even already-THF problems need the Lash-safe emission (explicit `@` and
  parenthesized equations), so the old "copy if already THF" shortcut is gone.
  """
  @spec ensure_thf(binary(), atom(), keyword()) :: binary()
  def ensure_thf(path, prover, opts \\ [])

  def ensure_thf(path, :lash, opts) do
    out_dir = Keyword.get(opts, :output_dir, Path.dirname(path))
    File.mkdir_p!(out_dir)
    base = Path.basename(path, ".p")
    out = Path.join(out_dir, "#{base}_thf.p")
    {^out, _} = convert_file(path, output_dir: out_dir)
    out
  end

  def ensure_thf(path, _prover, _opts), do: path

  @doc """
  Returns true if the problem needs THF conversion (is not already THF).
  """
  @spec needs_conversion?(binary()) :: boolean()
  def needs_conversion?(path) do
    content = File.read!(path)
    not String.match?(content, ~r/^% SPC.*THF/m)
  end

  # ── Header ────────────────────────────────────────────────────────────────

  defp split_header(lines) do
    Enum.split_while(lines, &(String.starts_with?(&1, "%") or String.trim(&1) == ""))
  end

  defp update_spc(header) do
    Enum.map(header, fn line ->
      Regex.replace(~r/^(%\s*SPC\s*:\s*)[A-Z]+_/, line, "\\1THF_")
    end)
  end

  # ── Entry / formula emission ──────────────────────────────────────────────

  # Lash does not accept the TPTP `negated_conjecture` role. In THF, an
  # Unsatisfiable problem's negated-conjecture clause `¬C` must be negated and
  # re-issued as the `conjecture` goal C (Lash refutes {axioms, ¬C}). Must be
  # declared before the generic `role:` clause below.
  defp emit_entry(%{name: name, role: "negated_conjecture", ast: ast}, bvars) do
    ast = TPTPToSMT.close_free_vars!(ast)
    "thf(#{name}, conjecture, #{emit_formula(negate(ast), bvars)})."
  end

  defp emit_entry(%{name: name, role: role, ast: ast}, bvars) do
    # TPTP CNF/FOF clauses may reference free variables (implicitly universal).
    ast = TPTPToSMT.close_free_vars!(ast)
    "thf(#{name}, #{role}, #{emit_formula(ast, bvars)})."
  end

  defp negate({:not, f}), do: f
  defp negate({:neq, l, r}), do: {:eq, l, r}
  defp negate({:eq, l, r}), do: {:neq, l, r}
  defp negate(f), do: {:not, f}

  defp emit_formula({true}, _bvars), do: "$true"
  defp emit_formula({false}, _bvars), do: "$false"
  defp emit_formula({:not, f}, bvars), do: "(~ #{emit_formula(f, bvars)})"

  defp emit_formula({:bin, op, l, r}, bvars) when op in ["&", "|", "=>", "<=>", "<~>"],
    do: "(#{emit_formula(l, bvars)} #{op} #{emit_formula(r, bvars)})"

  defp emit_formula({:forall, vars, body}, bvars),
    do: "![#{bindings(vars)}] : #{emit_formula(body, bvars)}"

  defp emit_formula({:exists, vars, body}, bvars),
    do: "?[#{bindings(vars)}] : #{emit_formula(body, bvars)}"

  # Lash binds `=` tighter than `@`, so equations must be fully parenthesized
  # (otherwise `identity @ X = X` is read as `identity @ (X = X)`).
  defp emit_formula({:eq, l, r}, _bvars), do: "((#{emit_term(l)}) = (#{emit_term(r)}))"

  defp emit_formula({:neq, l, r}, _bvars),
    do: "(~ ((#{emit_term(l)}) = (#{emit_term(r)})))"

  defp emit_formula({:pred, name, []}, _bvars), do: name

  defp emit_formula({:pred, name, args}, _bvars),
    do: "(#{name} @ #{Enum.map_join(args, " @ ", &emit_term/1)})"

  defp bindings(vars) do
    Enum.map_join(vars, ", ", fn {v, typ} ->
      "#{v}: #{if typ in [nil, ""], do: "$i", else: typ}"
    end)
  end

  defp emit_term({:var, v}), do: v
  defp emit_term({:const, c}), do: c
  defp emit_term({:num, n}), do: n
  defp emit_term({:bool, "true"}), do: "$true"
  defp emit_term({:bool, "false"}), do: "$false"
  defp emit_term({:func, f, []}), do: f

  defp emit_term({:func, f, args}),
    do: "(#{f} @ #{Enum.map_join(args, " @ ", &emit_term/1)})"

  defp emit_term({:app, name, args}),
    do: "(#{name} @ #{Enum.map_join(args, " @ ", &emit_term/1)})"

  # ── Type declarations ─────────────────────────────────────────────────────

  # Preserve explicit `thf(NAME, type, (SYM: TYPE)).` declarations from
  # already-THF problems (extracted by regex — the tokenizer drops the `>` of
  # arrow types). Otherwise types are inferred from the shared parser's
  # signature (preds → `$o`, funcs/consts → `$i`).
  defp extract_explicit_types(content) do
    ~r/thf\(\s*[A-Za-z0-9_]+\s*,\s*type\s*,\s*\(\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*([^)]+)\)\s*\)\s*\./
    |> Regex.scan(content)
    |> Enum.reduce(%{}, fn [_, sym, typ], acc -> Map.put(acc, sym, String.trim(typ)) end)
  end

  # Types are inferred from the shared parser's signature (preds → `$o`,
  # funcs/consts → `$i`). `$o`-quantified variables (bvars) are excluded —
  # declaring e.g. `thf(tp_P, type, (P: $o)).` while also binding `![P: $o]`
  # is a name clash that Lash rejects.
  defp generate_types(sig, explicit, bvars) do
    (Map.keys(sig.preds) ++ Map.keys(sig.funcs))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(bvars, &1))
    |> Enum.sort()
    |> Enum.map(fn name ->
      type_str =
        cond do
          Map.has_key?(explicit, name) -> explicit[name]
          Map.has_key?(sig.preds, name) -> pred_type(Map.fetch!(sig.preds, name))
          true -> func_type(Map.fetch!(sig.funcs, name))
        end

      "thf(tp_#{name}, type, (#{name}: #{type_str}))."
    end)
  end

  defp pred_type(0), do: "$o"
  defp pred_type(arity), do: (List.duplicate("$i >", arity) |> Enum.join(" ")) <> " $o"

  defp func_type(0), do: "$i"
  defp func_type(arity), do: (List.duplicate("$i >", arity) |> Enum.join(" ")) <> " $i"

  # ── Minimal fallback ──────────────────────────────────────────────────────

  # If the parser could not handle a problem at all (e.g. exotic higher-order
  # syntax), fall back to a bare `fof`/`cnf`/`tff` → `thf` rename rather than
  # emitting an empty problem.
  defp legacy_fallback(content, header) do
    body =
      content
      |> String.replace(~r/\b(fof|cnf|tff)\(/, "thf(")
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "%"))

    (update_spc(header) ++ body)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
