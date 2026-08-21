defmodule AtpBenchmarkRunner.TPTP.ToTHF do
  @moduledoc """
  Converts FOF/CNF/TFF TPTP problems to THF (typed higher-order form).

  Design: runs **outside** the container, in the Elixir runner, before the
  problem file is mounted/uploaded to Lash. This keeps the container simple
  (no Python, no wrapper scripts).

  ## Conversion rules

    1. Rename `fof(`/`cnf(`/`tff(` to `thf(`
    2. Scan for bare symbols — classify as propositions (`$o`) or
       function/constant symbols (`$i^n→$i`) based on usage context
    3. Generate type declarations before formulas
    4. Annotate quantified variables with `: $i`
    5. Update SPC header from `FOF_*`/`CNF_*` to `THF_*`
  """

  @known ~w(fof cnf tff thf type axiom conjecture hypothesis and or not
            impl equiv true false )

  @doc """
  Converts a TPTP problem string to THF. Returns converted string.
  """
  @spec convert_string(binary()) :: binary()
  def convert_string(content) when is_binary(content) do
    lines =
      content
      |> String.split(~r{[\r\n]+})
      |> Enum.map(&String.trim/1)
      |> merge_multiline_entries()

    {header, body} = split_header(lines)
    {sym, formulas} = process_formulas(body)
    types = generate_types(sym)

    ([update_spc(header), "", types, ""] ++ formulas)
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp merge_multiline_entries(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      is_start =
        String.starts_with?(line, "fof(") or String.starts_with?(line, "cnf(") or
          String.starts_with?(line, "thf(") or String.starts_with?(line, "tff(")

      cond do
        is_start and String.ends_with?(line, ".") ->
          [line | acc]

        is_start ->
          ["__MULTI__" <> line | acc]

        true ->
          case acc do
            ["__MULTI__" <> buf | rest] ->
              merged =
                if String.ends_with?(line, "."),
                  do: buf <> " " <> line,
                  else: "__MULTI__" <> buf <> " " <> line

              [merged | rest]

            _ ->
              [line | acc]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      "__MULTI__" <> entry -> entry
      entry -> entry
    end)
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
  Returns the path to a THF-converted problem for Lash, or the original
  path if no conversion is needed.
  """
  @spec ensure_thf(binary(), atom(), keyword()) :: binary()
  def ensure_thf(path, prover, opts \\ [])

  def ensure_thf(path, :lash, opts) do
    out_dir = Keyword.get(opts, :output_dir, Path.dirname(path))
    File.mkdir_p!(out_dir)
    base = Path.basename(path, ".p")
    out = Path.join(out_dir, "#{base}_thf.p")

    if needs_conversion?(path) do
      {^out, _} = convert_file(path, output_dir: out_dir)
      out
    else
      File.cp!(path, out)
      out
    end
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

  # ── Formula processing ────────────────────────────────────────────────────

  defp process_formulas(lines) do
    Enum.reduce(lines, {%{}, []}, fn
      "", {sym, out} ->
        {sym, out ++ [""]}

      line, {sym, out} when is_binary(line) ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "%") ->
            {sym, out ++ [line]}

          String.match?(trimmed, ~r/^thf\(/) ->
            {sym, out ++ [line]}

          String.match?(trimmed, ~r/^(fof|cnf|tff)\(/) ->
            {new_sym, converted} = convert_one(trimmed, sym)
            {new_sym, out ++ [converted]}

          true ->
            {sym, out ++ [line]}
        end
    end)
  end

  defp convert_one(line, sym) do
    body = String.trim_trailing(line, ".")

    case Regex.run(~r/^(fof|cnf|tff)\(\s*([^,]+?)\s*,\s*([^,]+?)\s*,\s*(.+)\)\s*$/, body) do
      [_, _kind, name, role, formula] ->
        formula = String.trim(formula)
        {new_sym, thf_formula} = convert_formula(formula, sym)
        {new_sym, "thf(#{name}, #{role}, #{thf_formula})."}

      nil ->
        {sym, line}
    end
  end

  # ── Formula conversion ────────────────────────────────────────────────────

  # Symbol table: %{name => %{arity: n, role: :predicate | :function | :proposition}}

  defp convert_formula(formula, sym) do
    {new_sym, _preds, _funcs} = extract_symbols(formula, sym)
    vars = collect_vars(formula)

    # Collect bare (non-applied) symbols that aren't vars
    bare =
      ~r/\b([a-z_][a-zA-Z0-9_]*)\b/
      |> Regex.scan(formula)
      |> Enum.map(fn [_, w] -> w end)
      |> Enum.reject(&(&1 in @known))
      |> Enum.reject(&MapSet.member?(vars, &1))
      |> Enum.reject(&(String.length(&1) == 1 and &1 >= "A" and &1 <= "Z"))
      |> Enum.reject(&Map.has_key?(new_sym, &1))

    new_sym =
      Enum.reduce(bare, new_sym, fn s, acc ->
        Map.put_new(acc, s, %{arity: 0, role: :proposition})
      end)

    thf =
      formula
      |> String.replace(~r/\b(fof|cnf|tff)\(/, "thf(")
      |> annotate_quants()

    {new_sym, thf}
  end

  @doc false
  # Extracts symbols with arities from a formula body.
  # Returns {symbol_map, top-level-predicates, nested-functions}
  def extract_symbols(formula, sym \\ %{}) do
    result =
      formula
      |> extract_all_applications()
      |> Enum.reduce(sym, fn {name, arity, depth}, acc ->
        role = if depth == 0, do: :predicate, else: :function
        entry = %{arity: arity, role: role}

        case Map.get(acc, name) do
          nil ->
            Map.put(acc, name, entry)

          %{arity: existing} when arity > existing ->
            Map.put(acc, name, %{arity: arity, role: role})

          %{role: :function} = _existing when role == :predicate ->
            # Promote: if same symbol used as predicate, prefer predicate role
            Map.put(acc, name, entry)

          _ ->
            acc
        end
      end)

    {result, Map.keys(result) |> Enum.filter(&(Map.get(result, &1).role == :predicate)),
     Map.keys(result) |> Enum.filter(&(Map.get(result, &1).role == :function))}
  end

  defp extract_all_applications(formula) do
    # Find all name( matches with positions
    name_opens =
      ~r/\b([a-z_][a-zA-Z0-9_]*)\s*\(/
      |> Regex.scan(formula, return: :index)
      |> Enum.map(fn [{ms, ml}, {ns, nl}] ->
        %{type: :open, name: String.slice(formula, ns, nl), pos: ms, match_len: ml}
      end)
      |> Enum.reject(fn %{name: n} -> n in @known end)

    # Find all ) positions
    close_positions =
      formula
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> c == ")" end)
      |> Enum.map(fn {_, i} -> %{type: :close, pos: i} end)

    # Merge and process in order
    events = Enum.sort_by(name_opens ++ close_positions, & &1.pos)

    {results, _stack} =
      Enum.reduce(events, {[], []}, fn
        %{type: :open, name: name, pos: pos, match_len: ml}, {acc, stack} ->
          depth = length(stack)
          # Extract args content
          rest = String.slice(formula, (pos + ml)..-1//1)
          args_str = extract_balanced_to_end(rest, 1)
          arity = count_top_args(args_str)
          {[{name, arity, depth} | acc], [pos | stack]}

        %{type: :close}, {acc, [_ | stack]} ->
          {acc, stack}

        %{type: :close}, {acc, []} ->
          {acc, []}
      end)

    results
  end

  defp extract_balanced_to_end(<<"">>, _depth), do: ""

  defp extract_balanced_to_end(<<c::utf8, rest::binary>>, depth) do
    case c do
      c when c in ~c"([{" ->
        inner = extract_balanced_to_end(rest, depth + 1)
        <<c::utf8>> <> inner

      c when c in ~c")]}" and depth == 1 ->
        <<c::utf8>>

      c when c in ~c")]}" ->
        <<c::utf8>> <> extract_balanced_to_end(rest, depth - 1)

      _ ->
        <<c::utf8>> <> extract_balanced_to_end(rest, depth)
    end
  end

  defp count_top_args(args_str) do
    args_str = String.trim_trailing(args_str, ")") |> String.trim()

    if args_str == "" do
      0
    else
      args_str
      |> String.trim()
      |> count_commas_at_depth_0(0)
    end
  end

  defp count_commas_at_depth_0(<<"">>, _depth), do: 1

  defp count_commas_at_depth_0(<<c::utf8, rest::binary>>, depth) do
    case c do
      c when c in ~c"([{" -> count_commas_at_depth_0(rest, depth + 1)
      c when c in ~c")]}" -> count_commas_at_depth_0(rest, depth - 1)
      ?, when depth == 0 -> 1 + count_commas_at_depth_0(rest, 0)
      _ -> count_commas_at_depth_0(rest, depth)
    end
  end

  defp collect_vars(formula) do
    ~r/[!?]\s*\[([^\]]+?)\]/
    |> Regex.scan(formula)
    |> Enum.flat_map(fn [_, vs] -> String.split(vs, ~r/[,;]/) end)
    |> Enum.map(fn v ->
      v |> String.trim() |> String.split(":") |> hd() |> String.trim()
    end)
    |> MapSet.new()
  end

  # ── Type declarations ─────────────────────────────────────────────────────

  defp generate_types(symbols) do
    symbols
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, %{arity: arity, role: role}} ->
      type_str =
        case role do
          :proposition ->
            "$o"

          :predicate when arity == 0 ->
            "$o"

          :predicate ->
            arrows = List.duplicate("$i", arity) |> Enum.join(" > ")
            "#{arrows} > $o"

          :function when arity == 0 ->
            "$i"

          :function ->
            arrows = List.duplicate("$i", arity + 1) |> Enum.join(" > ")
            arrows
        end

      "thf(tp_#{name}, type, (#{name}: #{type_str}))."
    end)
  end

  # ── Formula transformations ───────────────────────────────────────────────

  defp annotate_quants(formula) do
    Regex.replace(~r/([!?])\s*\[([^\]]+?)\]\s*:/, formula, fn _, q, vars ->
      typed =
        String.split(vars, ~r/[,;]/)
        |> Enum.map(fn v -> String.trim(v) end)
        |> Enum.map(fn v ->
          if String.contains?(v, ":"), do: v, else: "#{v}: $i"
        end)
        |> Enum.join(", ")

      "#{q} [#{typed}] :"
    end)
  end
end
