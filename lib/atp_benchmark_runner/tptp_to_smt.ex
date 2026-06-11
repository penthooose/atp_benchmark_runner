defmodule AtpBenchmarkRunner.TPTPToSMT do
  @moduledoc """
  Converts TPTP problem files to SMT-LIB format for provers that don't
  natively support TPTP (like CVC5's static build).

  Supports FOF and CNF formulas with propositional and first-order logic.
  THF (higher-order) is not supported — those provers handle it natively.

  ## Usage

      smt = AtpBenchmarkRunner.TPTPToSMT.convert_file!("problem.p")
      File.write!("problem.smt2", smt)
  """

  @doc """
  Reads a TPTP file and converts it to SMT-LIB format.
  """
  @spec convert_file!(binary()) :: binary()
  def convert_file!(path) when is_binary(path) do
    path
    |> File.read!()
    |> convert_string!()
  end

  @doc """
  Converts TPTP content string to SMT-LIB format.
  """
  @spec convert_string!(binary()) :: binary()
  def convert_string!(content) when is_binary(content) do
    tptp_entries = parse_tptp(content)
    smt2 = to_smt(tptp_entries)
    smt2
  end

  @doc """
  Tokenizes a TPTP file into individual formula entries.
  """
  def parse_tptp(content) when is_binary(content) do
    content
    |> String.split(~r{[\r\n]+})
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&String.starts_with?(&1, "%"))
    |> merge_multiline_entries()
    |> Enum.map(&remove_comment_suffix/1)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp merge_multiline_entries(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      is_start = String.starts_with?(line, "fof(") or
                 String.starts_with?(line, "cnf(") or
                 String.starts_with?(line, "thf(") or
                 String.starts_with?(line, "tff(")

      cond do
        is_start and String.ends_with?(line, ".") ->
          [line | acc]
        is_start ->
          ["__MULTI__" <> line | acc]
        true ->
          case acc do
            ["__MULTI__" <> buf | rest] ->
              merged = if String.ends_with?(line, ".") do
                buf <> " " <> line
              else
                "__MULTI__" <> buf <> " " <> line
              end
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
  Converts parsed TPTP entries to SMT-LIB format.
  """
  def to_smt(entries) when is_list(entries) do
    logic = detect_logic(entries)
    vars = extract_variables(entries)

    header = """
    (set-logic #{logic})
    (set-info :source "ATP Benchmark Runner TPTP-to-SMT converter")
    """

    declarations =
      vars
      |> Enum.map(&"(declare-const #{&1} Bool)")
      |> Enum.join("\n")

    assertions =
      entries
      |> Enum.map(&entry_to_smt/1)
      |> Enum.join("\n")

    check = "(check-sat)"

    [header, declarations, assertions, check]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # --- TPTP parsing ---

  defp remove_comment_suffix(line) do
    case String.split(line, "%", parts: 2) do
      [before_comment] -> before_comment
      [before_comment, _comment] -> before_comment
    end
    |> String.trim()
  end

  defp parse_entry(""), do: nil
  defp parse_entry("fof(" <> rest), do: parse_fof(rest)
  defp parse_entry("cnf(" <> rest), do: parse_cnf(rest)
  defp parse_entry("thf(" <> _rest), do: nil  # THF not supported
  defp parse_entry("tff(" <> _rest), do: nil  # TFF not supported yet
  defp parse_entry(_), do: nil

  defp parse_fof(rest) do
    # fof(name, role, formula).
    case split_tptp_args(rest) do
      [name, role, formula | _] ->
        %{
          type: :fof,
          name: clean_name(name),
          role: clean_role(role),
          formula: strip_trailing_dot(formula)
        }
      _ -> nil
    end
  end

  defp parse_cnf(rest) do
    # cnf(name, role, clause).
    case split_tptp_args(rest) do
      [name, role, clause | _] ->
        %{
          type: :cnf,
          name: clean_name(name),
          role: clean_role(role),
          formula: strip_trailing_dot(clause)
        }
      _ -> nil
    end
  end

  defp split_tptp_args(str) do
    str
    |> split_respecting_parens()
    |> Enum.map(&String.trim/1)
  end

  defp split_respecting_parens(str) do
    do_split(str, [], "", 0)
  end

  defp do_split("", acc, current, _depth), do: Enum.reverse([current | acc])
  defp do_split(")", acc, current, 1), do: do_split(")", acc, current, 0) # handle edge case

  defp do_split(<<c::utf8, rest::binary>>, acc, current, depth) do
    case c do
      ?( -> do_split(rest, acc, current <> <<c::utf8>>, depth + 1)
      ?) -> do_split(rest, acc, current <> <<c::utf8>>, depth - 1)
      ?, when depth == 0 ->
        do_split(rest, [current | acc], "", 0)
      _ -> do_split(rest, acc, current <> <<c::utf8>>, depth)
    end
  end

  defp clean_name(name), do: String.trim(name)
  defp clean_role(role), do: String.trim(role)
  defp strip_trailing_dot(str), do: String.trim_trailing(str, ".")

  # --- SMT-LIB conversion ---

  defp detect_logic(entries) do
    has_quantifiers =
      Enum.any?(entries, fn e ->
        String.contains?(e.formula, "! [") or String.contains?(e.formula, "? [")
      end)

    if has_quantifiers, do: "ALL", else: "ALL"
  end

  # Extract propositional variables from formulas to declare them in SMT-LIB
  # Walk the formula string and collect simple lowercase identifiers
  defp extract_variables(entries) do
    entries
    |> Enum.flat_map(fn e -> extract_vars_from_formula(e.formula) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_vars_from_formula(formula) do
    # Strip outer parentheses
    stripped = formula |> String.trim()

    # Tokenize on space, parens, and operators
    tokens =
      stripped
      |> String.replace(~r/[()\],]/, " $0 ")
      |> String.split(~r{\s+}, trim: true)

    # Known keywords/connectives that should NOT be declared as variables
    keywords = MapSet.new([
      "~", "|", "&", "=>", "<=", "<=>", "<~>", "=", "!=",
      "!", "?", "[", "]", ":", ".",
      "$true", "$false", "$false", "$true",
      "true", "false"
    ])

    tokens
    |> Enum.reject(&(MapSet.member?(keywords, &1)))
    # Keep simple lowercase identifiers (propositional atoms)
    |> Enum.filter(&(Regex.match?(~r/^[a-z][a-zA-Z0-9_]*$/, &1)))
    |> Enum.uniq()
  end

  defp entry_to_smt(%{type: :fof, role: role, formula: formula}) do
    converted = tptp_formula_to_smt(formula, 0)

    case role do
      "axiom" -> "(assert #{converted})"
      "hypothesis" -> "(assert #{converted})"
      "conjecture" -> "(assert (not #{converted}))"
      "negated_conjecture" -> "(assert #{converted})"
      "plain" -> "(assert #{converted})"
      "unknown" -> "(assert #{converted})"
      _ -> "(assert #{converted})"
    end
  end

  defp entry_to_smt(%{type: :cnf, formula: formula}) do
    converted = tptp_cnf_to_smt(formula)
    "(assert #{converted})"
  end

  defp entry_to_smt(_), do: ""

  @doc """
  Converts a TPTP FOF formula to SMT-LIB format.
  Handles propositional logic and simple first-order formulas.
  """
  def tptp_formula_to_smt(formula, _indent \\ 0)

  # Remove outer parentheses if present (TPTP sometimes wraps in extra parens)
  def tptp_formula_to_smt("(" <> rest, indent) do
    # Match balanced parentheses
    inner = strip_outer_parens("(" <> rest)
    if inner do
      tptp_formula_to_smt(inner, indent)
    else
      tptp_prop_to_smt("(" <> rest, indent)
    end
  end

  def tptp_formula_to_smt(formula, indent) do
    tptp_prop_to_smt(formula, indent)
  end

  defp tptp_prop_to_smt(formula, indent) do
    cond do
      # Quantifiers: ! [X:] : Body
      String.starts_with?(formula, "! [") ->
        convert_quantifier(formula, :forall, indent)

      # Quantifiers: ? [X:] : Body
      String.starts_with?(formula, "? [") ->
        convert_quantifier(formula, :exists, indent)

      # $true / $false
      formula == "$true" -> "true"
      formula == "$false" -> "false"

      # Negation: ~ F (handle leading whitespace and ~ without space)
      String.trim(formula) |> String.starts_with?("~") ->
        inner = formula |> String.trim() |> String.trim_leading("~") |> String.trim()
        "(not #{tptp_formula_to_smt(inner, indent)})"

      # Equality: F1 = F2 (in CNF-context, tptp uses = for equality)
      String.contains?(formula, " = ") ->
        case split_top_level(formula, "=") do
          [left, right] ->
            "(= #{tptp_formula_to_smt(left, indent)} #{tptp_formula_to_smt(right, indent)})"
          _ -> "\"#{escape_formula(formula)}\""
        end

      # Inequality: F1 != F2
      String.contains?(formula, " != ") ->
        case split_top_level(formula, "!=") do
          [left, right] ->
            "(not (= #{tptp_formula_to_smt(left, indent)} #{tptp_formula_to_smt(right, indent)}))"
          _ -> "\"#{escape_formula(formula)}\""
        end

      # Implication: F1 => F2
      String.contains?(formula, " => ") ->
        case split_top_level(formula, "=>") do
          [left, right] ->
            "(=> #{tptp_formula_to_smt(left, indent)} #{tptp_formula_to_smt(right, indent)})"
          _ -> "\"#{escape_formula(formula)}\""
        end

      # Equivalence: F1 <=> F2
      String.contains?(formula, " <=> ") ->
        case split_top_level(formula, "<=>") do
          [left, right] ->
            "(= #{tptp_formula_to_smt(left, indent)} #{tptp_formula_to_smt(right, indent)})"
          _ -> "\"#{escape_formula(formula)}\""
        end

      # Xor: F1 <~> F2
      String.contains?(formula, " <~> ") ->
        case split_top_level(formula, "<~>") do
          [left, right] ->
            "(xor #{tptp_formula_to_smt(left, indent)} #{tptp_formula_to_smt(right, indent)})"
          _ -> "\"#{escape_formula(formula)}\""
        end

      # Or: F1 | F2
      String.contains?(formula, " | ") ->
        case split_top_level(formula, "|") do
          clauses -> "(or #{Enum.map_join(clauses, " ", &tptp_formula_to_smt(&1, indent))})"
        end

      # And: F1 & F2
      String.contains?(formula, " & ") ->
        case split_top_level(formula, "&") do
          conjuncts -> "(and #{Enum.map_join(conjuncts, " ", &tptp_formula_to_smt(&1, indent))})"
        end

      # Simple predicate or atom
      true -> tptp_atom_to_smt(formula)
    end
  end

  defp tptp_cnf_to_smt(formula) do
    # CNF clause: l1 | l2 | ... | ln
    if String.contains?(formula, " | ") do
      literals = split_top_level(formula, "|")
      "(or #{Enum.map_join(literals, " ", &tptp_literal_to_smt/1)})"
    else
      tptp_literal_to_smt(formula)
    end
  end

  defp tptp_literal_to_smt(literal) do
    lit = String.trim(literal)
    if String.starts_with?(lit, "~") do
      inner = String.trim_leading(lit, "~") |> String.trim()
      # Check if the inner part has parentheses to strip
      inner_clean = if String.starts_with?(inner, "(") and String.ends_with?(inner, ")"),
                       do: String.slice(inner, 1..-2//-1) |> String.trim(),
                       else: inner
      "(not #{tptp_prop_to_smt(inner_clean, 0)})"
    else
      tptp_prop_to_smt(lit, 0)
    end
  end

  defp tptp_atom_to_smt(atom) do
    atom = String.trim(atom)
    cond do
      atom == "$true" -> "true"
      atom == "$false" -> "false"
      true ->
        # TPTP predicate: p(a,b) or just p
        # Simple: just pass through known atoms
        # For variables: use lowercase
        # For constants/functions: pass through
        atom
    end
  end

  defp convert_quantifier(formula, type, indent) do
    # Format: ! [X:type] : Body or ? [X:type] : Body
    inner = String.trim_leading(formula, if(type == :forall, do: "! [", else: "? ["))

    # Extract variables up to ]
    case String.split(inner, "]", parts: 2) do
      [vars_part, rest] ->
        vars = parse_quantified_vars(vars_part)
        body = String.trim_leading(rest, ":") |> String.trim()
        q = if type == :forall, do: "forall", else: "exists"

        smt_vars =
          Enum.map(vars, fn {name, _type_str} ->
            "(#{name} Bool)"
          end)
          |> Enum.join(" ")

        "(#{q} (#{smt_vars}) #{tptp_formula_to_smt(body, indent + 1)})"

      _ -> formula
    end
  end

  defp parse_quantified_vars(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(fn v ->
      v = String.trim(v)
      case String.split(v, ":", parts: 2) do
        [name, type] -> {String.trim(name), String.trim(type)}
        [name] -> {String.trim(name), ""}
      end
    end)
  end

  # --- Helpers ---

  defp strip_outer_parens("(" <> rest) do
    rest = String.trim_trailing(rest, ")")
    case count_parens("(" <> rest) do
      {1, _} -> String.trim(rest)
      _ -> nil
    end
  end

  defp count_parens(str) do
    String.graphemes(str)
    |> Enum.reduce({0, 0}, fn
      "(", {open, close} -> {open + 1, close}
      ")", {open, close} when open > 0 -> {open, close + 1}
      _, acc -> acc
    end)
  end

  defp split_top_level(str, delimiter) do
    pattern = ~r/\s+#{Regex.escape(delimiter)}\s+/
    String.split(str, pattern, trim: true)
  end

  defp escape_formula(str), do: str |> String.replace(~r/[^a-zA-Z0-9_()]/, "_")
end
