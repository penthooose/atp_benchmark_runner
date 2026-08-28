defmodule AtpBenchmarkRunner.TPTPToSMT do
  @moduledoc """
  Converts TPTP problem files (FOF/CNF/TFF/THF) to SMT-LIB 2.6.

  cvc5 has no TPTP input dialect (its `--lang` option only accepts
  `smt2`/`smtlib`, `smt2-tptp` and `sygus`), so problems must be converted to
  SMT-LIB before they reach the container. This is a real tokenizer plus
  recursive-descent parser, so it handles quantified first-order formulas,
  functions, predicates, equality and the common TPTP connectives.

  ## Design

    * TPTP individuals live in one uninterpreted sort `U`.
    * User symbols are prefixed with `tptp.` (matching cvc5's own converter) to
      avoid clashing with SMT-LIB reserved words.
    * `$o`-typed quantified variables become `Bool`; everything else becomes `U`.
    * A `conjecture` entry is asserted negated (a theorem is then `unsat` on
      `check-sat`); `negated_conjecture` is asserted as-is.
    * `type`-role declarations are skipped.

  Known limitation: higher-order `@`-application and `^`-lambda (rare in the
  benchmark set) are unsupported and raise `ArgumentError`. Callers should
  handle that per-problem so one unsupported problem does not abort a run.
  """

  alias AtpBenchmarkRunner.Config

  @token_regex ~r/<=>|=>|<~>|!=|~|[&|=!?(),\[\]:.@]|\^|[A-Za-z_$][A-Za-z0-9_$]*|\d+|'[^']*'/

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

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
  Reads a TPTP file, converts to SMT-LIB, and writes it to the configured temp
  directory. Returns the path to the written `.smt2` file.
  """
  @spec convert_file_to_path!(binary(), keyword()) :: binary()
  def convert_file_to_path!(path, opts \\ []) when is_binary(path) do
    smt = convert_file!(path)
    dir = Config.smt_tmp_dir(opts)
    File.mkdir_p!(dir)

    base = path |> Path.basename(".p") |> Path.basename(".tptp")
    out = Path.join(dir, "#{base}.smt2")
    File.write!(out, smt)
    out
  end

  @doc """
  Converts TPTP content to SMT-LIB format.
  """
  @spec convert_string!(binary()) :: binary()
  def convert_string!(content) when is_binary(content) do
    content
    |> tokenize()
    |> parse_entries()
    |> to_smt()
  end

  @doc """
  Parses a TPTP problem string into AST entries. Also used by the THF converter
  (`TPTP.ToTHF`) so both share one tokenizer/parser. Each entry is
  `%{type, name, role, ast}`; `type`-role declarations and unparseable
  entries are skipped.
  """
  @spec parse_string!(binary()) :: [map()]
  def parse_string!(content) when is_binary(content) do
    content
    |> tokenize()
    |> parse_entries()
  end

  @doc """
  Collects the signature for parsed entries: `{sig, bool_vars}` where
  `sig = %{preds: %{name => arity}, funcs: %{name => arity}}` and `bool_vars`
  is the set of `$o`-quantified variable names.
  """
  @spec collect_signature!([map()]) :: {map(), MapSet.t()}
  def collect_signature!(entries) do
    sig =
      Enum.reduce(entries, empty_sig(), fn %{ast: ast}, acc ->
        collect_sig(ast, acc)
      end)

    bvars =
      Enum.reduce(entries, MapSet.new(), fn %{ast: ast}, acc ->
        collect_bool_vars(ast, acc)
      end)

    {sig, bvars}
  end

  @doc """
  Closes free variables with an implicit universal quantifier (TPTP CNF/FOF
  semantics: a bare `cnf(..., (p(X)))` clause's `X` is universally quantified).
  Returns a new AST with the free variables wrapped in `forall`.
  """
  @spec close_free_vars!(term()) :: term()
  def close_free_vars!(ast) do
    case free_vars(ast) do
      [] -> ast
      vars -> {:forall, Enum.map(vars, &{&1, nil}), ast}
    end
  end

  # ---------------------------------------------------------------------------
  # Tokenizer
  # ---------------------------------------------------------------------------

  defp tokenize(content) do
    content
    |> strip_comments()
    |> then(&Regex.scan(@token_regex, &1))
    |> List.flatten()
    |> Enum.map(&classify_token/1)
  end

  defp strip_comments(content) do
    content
    |> String.split("\n")
    |> Enum.map(fn line ->
      case String.split(line, "%", parts: 2) do
        [before | _] -> before
      end
    end)
    |> Enum.join("\n")
  end

  defp classify_token("("), do: {:punct, "("}
  defp classify_token(")"), do: {:punct, ")"}
  defp classify_token("["), do: {:punct, "["}
  defp classify_token("]"), do: {:punct, "]"}
  defp classify_token(","), do: {:punct, ","}
  defp classify_token(":"), do: {:punct, ":"}
  defp classify_token("."), do: {:punct, "."}
  defp classify_token("~"), do: {:op, "~"}
  defp classify_token("&"), do: {:op, "&"}
  defp classify_token("|"), do: {:op, "|"}
  defp classify_token("="), do: {:op, "="}
  defp classify_token("!"), do: {:op, "!"}
  defp classify_token("?"), do: {:op, "?"}
  defp classify_token("=>"), do: {:op, "=>"}
  defp classify_token("<=>"), do: {:op, "<=>"}
  defp classify_token("<~>"), do: {:op, "<~>"}
  defp classify_token("!="), do: {:op, "!="}
  defp classify_token("@"), do: {:op, "@"}
  defp classify_token("^"), do: {:op, "^"}

  defp classify_token(<<"'"::utf8, rest::binary>>), do: {:ident, String.trim_trailing(rest, "'")}

  defp classify_token(tok) do
    if Regex.match?(~r/^\d+$/, tok), do: {:num, tok}, else: {:ident, tok}
  end

  # ---------------------------------------------------------------------------
  # Entry splitting
  # ---------------------------------------------------------------------------

  # Split tokens into TPTP entries at top-level ".". Round and square brackets
  # both count toward depth, so commas inside `![X1, X2] :` var lists never
  # split an entry.
  defp parse_entries(tokens) do
    tokens
    |> split_entries()
    |> Enum.flat_map(&parse_entry/1)
  end

  defp split_entries(tokens), do: split_entries(tokens, 0, [], [])

  defp split_entries([], _depth, cur, acc), do: Enum.reverse([Enum.reverse(cur) | acc])

  defp split_entries([{:punct, "("} | rest], depth, cur, acc),
    do: split_entries(rest, depth + 1, [{:punct, "("} | cur], acc)

  defp split_entries([{:punct, ")"} | rest], depth, cur, acc),
    do: split_entries(rest, depth - 1, [{:punct, ")"} | cur], acc)

  defp split_entries([{:punct, "["} | rest], depth, cur, acc),
    do: split_entries(rest, depth + 1, [{:punct, "["} | cur], acc)

  defp split_entries([{:punct, "]"} | rest], depth, cur, acc),
    do: split_entries(rest, depth - 1, [{:punct, "]"} | cur], acc)

  defp split_entries([{:punct, "."} | rest], 0, cur, acc),
    do: split_entries(rest, 0, [], [Enum.reverse(cur) | acc])

  defp split_entries([t | rest], depth, cur, acc),
    do: split_entries(rest, depth, [t | cur], acc)

  # Parse one entry: [fof|cnf|tff|thf] ( name , role , <formula> ).
  # `type`-role declarations and entries that do not parse are skipped.
  defp parse_entry([{:ident, kind} | rest]) when kind in ["fof", "cnf", "tff", "thf"] do
    with [{:punct, "("} | inner] <- rest,
         parts when length(parts) >= 3 <- split_at_top(inner, ","),
         [name_tokens, role_tokens, formula_tokens | _] <- parts,
         {:ok, name} <- single_ident(name_tokens),
         {:ok, role} <- single_ident(role_tokens),
         false <- role == "type" do
      formula_tokens = formula_tokens |> trim_dots() |> strip_closing_paren()

      case parse_safely(formula_tokens) do
        {:ok, ast} -> [%{type: kind, name: name, role: role, ast: ast}]
        :error -> []
      end
    else
      _ -> []
    end
  end

  defp parse_entry(_), do: []

  # Parse a formula, returning :error on unsupported syntax or leftover tokens
  # so one bad entry never aborts a run.
  defp parse_safely(tokens) do
    case parse_formula(tokens) do
      {ast, []} -> {:ok, ast}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Split a token list on a separator token at depth 0 (round + square depth).
  defp split_at_top(tokens, sep), do: do_split_at_top(tokens, sep, 0, [], [])

  defp do_split_at_top([], _sep, _depth, cur, acc),
    do: Enum.reverse([Enum.reverse(cur) | acc])

  defp do_split_at_top([{:punct, "("} | rest], sep, depth, cur, acc),
    do: do_split_at_top(rest, sep, depth + 1, [{:punct, "("} | cur], acc)

  defp do_split_at_top([{:punct, ")"} | rest], sep, depth, cur, acc),
    do: do_split_at_top(rest, sep, depth - 1, [{:punct, ")"} | cur], acc)

  defp do_split_at_top([{:punct, "["} | rest], sep, depth, cur, acc),
    do: do_split_at_top(rest, sep, depth + 1, [{:punct, "["} | cur], acc)

  defp do_split_at_top([{:punct, "]"} | rest], sep, depth, cur, acc),
    do: do_split_at_top(rest, sep, depth - 1, [{:punct, "]"} | cur], acc)

  defp do_split_at_top([t | rest], sep, 0, cur, acc) when t == {:punct, sep},
    do: do_split_at_top(rest, sep, 0, [], [Enum.reverse(cur) | acc])

  defp do_split_at_top([t | rest], sep, depth, cur, acc),
    do: do_split_at_top(rest, sep, depth, [t | cur], acc)

  defp single_ident([{:ident, id}]), do: {:ok, id}
  defp single_ident(_), do: :error

  defp trim_dots(tokens), do: Enum.reject(tokens, &(&1 == {:punct, "."}))

  # Remove the single closing paren of `fof(...)` from the end of the formula.
  defp strip_closing_paren(tokens) do
    case List.last(tokens) do
      {:punct, ")"} -> Enum.drop(tokens, -1)
      _ -> tokens
    end
  end

  # ---------------------------------------------------------------------------
  # Formula parser (recursive descent over the token list)
  # ---------------------------------------------------------------------------

  # AST:
  #   {:forall, [{var, type}], body} | {:exists, ...}
  #   {:not, f} | {:bin, op_string, l, r} | {:true} | {:false}
  #   {:pred, name, [term]}                 # predicate application
  #   {:eq, term, term} | {:neq, term, term}
  #   term: {:func, name, [term]} | {:var, name} | {:const, name} | {:num, s}
  #         | {:bool, "true"|"false"}

  defp parse_formula(tokens) do
    {left, rest} = parse_binary(tokens)
    {left, rest}
  end

  defp parse_binary(tokens) do
    {left, rest} = parse_unary(tokens)
    parse_binary_rest(rest, left)
  end

  defp parse_binary_rest([{:op, op} | rest], left) when op in ["=>", "<=>", "<~>", "&", "|"] do
    {right, rest2} = parse_unary(rest)
    parse_binary_rest(rest2, {:bin, op, left, right})
  end

  defp parse_binary_rest(tokens, left), do: {left, tokens}

  defp parse_unary([{:op, "~"} | rest]) do
    {f, rest2} = parse_unary(rest)
    {{:not, f}, rest2}
  end

  defp parse_unary(tokens), do: parse_atomic(tokens)

  defp parse_atomic([{:op, "!"}, {:punct, "["} | rest]), do: parse_quant(:forall, rest)
  defp parse_atomic([{:op, "?"}, {:punct, "["} | rest]), do: parse_quant(:exists, rest)

  defp parse_atomic([{:punct, "("} | rest]) do
    {f, rest2} = parse_formula(rest)

    case rest2 do
      [{:punct, ")"} | rest3] ->
        {f, rest3}

      _ ->
        raise ArgumentError, "TPTPToSMT: unbalanced parentheses in formula"
    end
  end

  defp parse_atomic([{:ident, "$true"} | rest]), do: {{true}, rest}
  defp parse_atomic([{:ident, "$false"} | rest]), do: {{false}, rest}
  defp parse_atomic([{:ident, name} | rest]), do: parse_atom_call(name, rest)
  defp parse_atomic([{:op, "@"} | _]), do: raise_ho("@")
  defp parse_atomic([{:op, "^"} | _]), do: raise_ho("^")
  defp parse_atomic(_), do: raise(ArgumentError, "TPTPToSMT: cannot parse formula")

  # An identifier at formula level: either a predicate application `p(t,...)`,
  # a nullary predicate `p`, a term equality `t = t` / `t != t`, or a THF
  # higher-order application `f @ a @ b`.
  defp parse_atom_call(name, tokens) do
    case tokens do
      [{:op, "@"} | _] ->
        {term, rest} = parse_term([{:ident, name} | tokens])

        case rest do
          [{:op, "="} | rest2] ->
            {right, rest3} = parse_term(rest2)
            {{:eq, term, right}, rest3}

          [{:op, "!="} | rest2] ->
            {right, rest3} = parse_term(rest2)
            {{:neq, term, right}, rest3}

          _ ->
            {{:pred, name, app_args(term)}, rest}
        end

      [{:punct, "("} | rest] ->
        {args, rest2} = parse_arg_list(rest)

        case rest2 do
          [{:op, "="} | rest3] ->
            {right, rest4} = parse_term(rest3)
            {{:eq, {:func, name, args}, right}, rest4}

          [{:op, "!="} | rest3] ->
            {right, rest4} = parse_term(rest3)
            {{:neq, {:func, name, args}, right}, rest4}

          _ ->
            {{:pred, name, args}, rest2}
        end

      [{:op, "="} | rest] ->
        {right, rest2} = parse_term(rest)
        {{:eq, term_ident(name), right}, rest2}

      [{:op, "!="} | rest] ->
        {right, rest2} = parse_term(rest)
        {{:neq, term_ident(name), right}, rest2}

      _ ->
        {{:pred, name, []}, tokens}
    end
  end

  # A THF application term `f @ a @ b` parses to `{:func, f, [a, b]}` for a
  # constant/function head; extract the argument list for a predicate reading.
  defp app_args({:func, _, args}), do: args
  defp app_args(_), do: []

  defp parse_quant(kind, tokens) do
    {vars, rest} = parse_var_list(tokens)

    case rest do
      [{:punct, "]"}, {:punct, ":"} | rest2] ->
        {body, rest3} = parse_formula(rest2)
        {{kind, vars, body}, rest3}

      _ ->
        raise ArgumentError, "TPTPToSMT: malformed quantifier"
    end
  end

  # Quantified variables until "]". Each is `name` optionally `: <type>`.
  defp parse_var_list(tokens, acc \\ [])

  defp parse_var_list([{:ident, v} | rest], acc) do
    {rest1, typ} = consume_var_type(rest)

    case rest1 do
      [{:punct, ","} | rest2] -> parse_var_list(rest2, [{v, typ} | acc])
      _ -> {Enum.reverse([{v, typ} | acc]), rest1}
    end
  end

  defp parse_var_list(tokens, acc), do: {Enum.reverse(acc), tokens}

  defp consume_var_type([{:punct, ":"} | rest]) do
    {rest2, type} = skip_type_tokens(rest, [])
    {rest2, type}
  end

  defp consume_var_type(tokens), do: {tokens, nil}

  defp skip_type_tokens([{:punct, ","} | _] = t, acc), do: {t, join_type(acc)}
  defp skip_type_tokens([{:punct, "]"} | _] = t, acc), do: {t, join_type(acc)}

  defp skip_type_tokens([{:ident, i} | rest], acc), do: skip_type_tokens(rest, [i | acc])
  defp skip_type_tokens([{:punct, p} | rest], acc), do: skip_type_tokens(rest, [p | acc])
  defp skip_type_tokens([{:op, o} | rest], acc), do: skip_type_tokens(rest, [o | acc])
  defp skip_type_tokens([], acc), do: {[], join_type(acc)}

  defp join_type([]), do: nil
  defp join_type(tokens), do: tokens |> Enum.reverse() |> Enum.join()

  # ---------------------------------------------------------------------------
  # Term parser
  # ---------------------------------------------------------------------------

  defp parse_term(tokens) do
    {head, rest} = parse_term_head(tokens)
    parse_app_chain(rest, head)
  end

  defp parse_term_head([{:ident, "$true"} | rest]), do: {{:bool, "true"}, rest}
  defp parse_term_head([{:ident, "$false"} | rest]), do: {{:bool, "false"}, rest}

  defp parse_term_head([{:ident, name} | rest]) do
    case rest do
      [{:punct, "("} | rest2] ->
        {args, rest3} = parse_arg_list(rest2)
        {{:func, name, args}, rest3}

      _ ->
        {term_ident(name), rest}
    end
  end

  defp parse_term_head([{:num, n} | rest]), do: {{:num, n}, rest}

  defp parse_term_head([{:punct, "("} | rest]) do
    {t, rest2} = parse_term(rest)

    case rest2 do
      [{:punct, ")"} | rest3] -> {t, rest3}
      _ -> raise ArgumentError, "TPTPToSMT: unbalanced parentheses in term"
    end
  end

  defp parse_term_head([{:op, "@"} | _]), do: raise_ho("@")
  defp parse_term_head([{:op, "^"} | _]), do: raise_ho("^")
  defp parse_term_head(_), do: raise(ArgumentError, "TPTPToSMT: cannot parse term")

  # Curried THF application `f @ a @ b` collects arguments (left-associative).
  defp parse_app_chain([{:op, "@"} | rest], head) do
    {arg, rest2} = parse_term_head(rest)
    parse_app_chain(rest2, apply_arg(head, arg))
  end

  defp parse_app_chain(tokens, head), do: {head, tokens}

  defp apply_arg({:func, name, args}, arg), do: {:func, name, args ++ [arg]}
  defp apply_arg({:const, name}, arg), do: {:func, name, [arg]}
  defp apply_arg({:var, name}, arg), do: {:app, name, [arg]}
  defp apply_arg({:app, name, args}, arg), do: {:app, name, args ++ [arg]}

  defp apply_arg(other, _arg) do
    raise ArgumentError, "TPTPToSMT: cannot apply term: #{inspect(other)}"
  end

  defp term_ident(name) do
    if uppercase_var?(name), do: {:var, name}, else: {:const, name}
  end

  defp parse_arg_list(tokens, acc \\ [])

  defp parse_arg_list([{:punct, ")"} | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_arg_list(tokens, acc) do
    {t, rest} = parse_term(tokens)

    case rest do
      [{:punct, ","} | rest2] -> parse_arg_list(rest2, [t | acc])
      _ -> parse_arg_list(rest, [t | acc])
    end
  end

  defp uppercase_var?(<<c::utf8, _::binary>>), do: c in ?A..?Z
  defp uppercase_var?(_), do: false

  defp raise_ho(what) do
    raise ArgumentError,
          "TPTPToSMT: unsupported higher-order syntax '#{what}' " <>
            "(lambda/application conversion to SMT-LIB is not implemented)"
  end

  # ---------------------------------------------------------------------------
  # SMT-LIB emission
  # ---------------------------------------------------------------------------

  defp to_smt(entries) do
    sig =
      Enum.reduce(entries, empty_sig(), fn %{ast: ast}, acc ->
        collect_sig(ast, acc)
      end)

    bvars =
      Enum.reduce(entries, MapSet.new(), fn %{ast: ast}, acc -> collect_bool_vars(ast, acc) end)

    decls = sort_decls() ++ predicate_decls(sig, bvars) ++ function_decls(sig)
    assertions = Enum.map(entries, &assertion_smt(&1, bvars))

    [
      "(set-logic ALL)",
      "(set-info :source \"ATP Benchmark Runner TPTP-to-SMT converter\")",
      decls,
      assertions,
      "(check-sat)"
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp empty_sig, do: %{preds: %{}, funcs: %{}}

  defp sort_decls, do: ["(declare-sort U 0)"]

  defp predicate_decls(sig, bvars) do
    sig.preds
    |> Enum.sort()
    |> Enum.reject(fn {name, _} -> MapSet.member?(bvars, name) end)
    |> Enum.map(fn {name, arity} ->
      "(declare-fun #{sym(name)} (#{args_sorts(arity)}) Bool)"
    end)
  end

  defp function_decls(sig) do
    sig.funcs
    |> Enum.sort()
    |> Enum.map(fn {name, arity} ->
      "(declare-fun #{sym(name)} (#{args_sorts(arity)}) U)"
    end)
  end

  defp args_sorts(0), do: ""
  defp args_sorts(n), do: List.duplicate("U", n) |> Enum.join(" ")

  defp assertion_smt(%{role: "conjecture", ast: ast}, bvars) do
    ast = close_vars(ast)
    "(assert (not #{fmla_smt(ast, bvars)}))"
  end

  defp assertion_smt(%{ast: ast}, bvars) do
    ast = close_vars(ast)
    "(assert #{fmla_smt(ast, bvars)})"
  end

  # TPTP semantics: free variables are implicitly universally quantified (this
  # is what makes bare CNF clauses such as `cnf(f01, axiom, (mult(X1,...)=...))`
  # legal; without closure their X1/X2 would be undeclared in SMT-LIB).
  defp close_vars(ast) do
    case free_vars(ast) do
      [] -> ast
      vars -> {:forall, Enum.map(vars, &{&1, nil}), ast}
    end
  end

  # Bottom-up free-variable computation: free(∀x.F) = free(F) \ {x}. Each
  # subtree returns its own free set, otherwise a single accumulator would mix
  # bound and free names.
  defp free_vars(ast) do
    ast
    |> do_free_vars()
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp do_free_vars({:forall, vars, body}) do
    MapSet.difference(do_free_vars(body), bound_names(vars))
  end

  defp do_free_vars({:exists, vars, body}) do
    MapSet.difference(do_free_vars(body), bound_names(vars))
  end

  defp do_free_vars({:not, f}), do: do_free_vars(f)
  defp do_free_vars({:bin, _, l, r}), do: MapSet.union(do_free_vars(l), do_free_vars(r))
  defp do_free_vars({:eq, l, r}), do: MapSet.union(term_free_vars(l), term_free_vars(r))
  defp do_free_vars({:neq, l, r}), do: MapSet.union(term_free_vars(l), term_free_vars(r))

  defp do_free_vars({:pred, _, args}),
    do: Enum.reduce(args, MapSet.new(), &merge_term_free/2)

  defp do_free_vars(_), do: MapSet.new()

  defp bound_names(vars), do: MapSet.new(vars, fn {v, _} -> v end)

  defp term_free_vars({:var, v}), do: MapSet.new([v])
  defp term_free_vars({:func, _, args}), do: Enum.reduce(args, MapSet.new(), &merge_term_free/2)

  defp term_free_vars({:app, name, args}),
    do: Enum.reduce(args, MapSet.new([name]), &merge_term_free/2)

  defp term_free_vars(_), do: MapSet.new()

  defp merge_term_free(term, acc), do: MapSet.union(acc, term_free_vars(term))

  defp fmla_smt({true}, _bvars), do: "true"
  defp fmla_smt({false}, _bvars), do: "false"
  defp fmla_smt({:not, f}, bvars), do: "(not #{fmla_smt(f, bvars)})"
  defp fmla_smt({:bin, "&", l, r}, bvars), do: "(and #{fmla_smt(l, bvars)} #{fmla_smt(r, bvars)})"
  defp fmla_smt({:bin, "|", l, r}, bvars), do: "(or #{fmla_smt(l, bvars)} #{fmla_smt(r, bvars)})"
  defp fmla_smt({:bin, "=>", l, r}, bvars), do: "(=> #{fmla_smt(l, bvars)} #{fmla_smt(r, bvars)})"
  defp fmla_smt({:bin, "<=>", l, r}, bvars), do: "(= #{fmla_smt(l, bvars)} #{fmla_smt(r, bvars)})"

  defp fmla_smt({:bin, "<~>", l, r}, bvars),
    do: "(xor #{fmla_smt(l, bvars)} #{fmla_smt(r, bvars)})"

  defp fmla_smt({:forall, vars, body}, bvars),
    do: "(forall #{bindings(vars)} #{fmla_smt(body, bvars)})"

  defp fmla_smt({:exists, vars, body}, bvars),
    do: "(exists #{bindings(vars)} #{fmla_smt(body, bvars)})"

  defp fmla_smt({:eq, l, r}, _bvars), do: "(= #{term_smt(l)} #{term_smt(r)})"
  defp fmla_smt({:neq, l, r}, _bvars), do: "(not (= #{term_smt(l)} #{term_smt(r)}))"

  defp fmla_smt({:pred, name, []}, bvars) do
    if MapSet.member?(bvars, name), do: name, else: sym(name)
  end

  defp fmla_smt({:pred, name, args}, _bvars),
    do: "(#{sym(name)} #{Enum.map_join(args, " ", &term_smt/1)})"

  defp term_smt({:var, v}), do: v
  defp term_smt({:const, c}), do: sym(c)
  defp term_smt({:num, n}), do: n
  defp term_smt({:bool, b}), do: b
  defp term_smt({:func, f, []}), do: sym(f)
  defp term_smt({:func, f, args}), do: "(#{sym(f)} #{Enum.map_join(args, " ", &term_smt/1)})"
  defp term_smt({:app, name, args}), do: "(#{name} #{Enum.map_join(args, " ", &term_smt/1)})"

  defp bindings(vars) do
    "(" <>
      Enum.map_join(vars, " ", fn {v, typ} -> "(#{v} #{var_sort(typ)})" end) <>
      ")"
  end

  defp var_sort("$o"), do: "Bool"
  defp var_sort(_), do: "U"

  defp sym(name), do: "tptp." <> name

  # ---------------------------------------------------------------------------
  # Signature collection
  # ---------------------------------------------------------------------------

  # Note: signatures are (ast, sig) / (term, sig), so do not pipe these
  # functions, the pipe would swap the arguments.
  defp collect_sig({:forall, _, body}, sig), do: collect_sig(body, sig)
  defp collect_sig({:exists, _, body}, sig), do: collect_sig(body, sig)
  defp collect_sig({:not, f}, sig), do: collect_sig(f, sig)
  defp collect_sig({:bin, _, l, r}, sig), do: collect_sig(r, collect_sig(l, sig))
  defp collect_sig({:eq, l, r}, sig), do: collect_term_sig(r, collect_term_sig(l, sig))
  defp collect_sig({:neq, l, r}, sig), do: collect_term_sig(r, collect_term_sig(l, sig))

  defp collect_sig({:pred, name, args}, sig) do
    sig
    |> add_sym(:preds, name, length(args))
    |> then(fn s -> Enum.reduce(args, s, &collect_term_sig/2) end)
  end

  defp collect_sig({true}, sig), do: sig
  defp collect_sig({false}, sig), do: sig

  defp collect_term_sig({:func, name, args}, sig) do
    sig
    |> add_sym(:funcs, name, length(args))
    |> then(fn s -> Enum.reduce(args, s, &collect_term_sig/2) end)
  end

  defp collect_term_sig({:const, name}, sig), do: add_sym(sig, :funcs, name, 0)
  defp collect_term_sig({:var, _}, sig), do: sig
  defp collect_term_sig({:num, _}, sig), do: sig
  defp collect_term_sig({:bool, _}, sig), do: sig
  defp collect_term_sig({:app, _, args}, sig), do: Enum.reduce(args, sig, &collect_term_sig/2)

  defp add_sym(sig, kind, name, arity) do
    current = Map.fetch!(sig, kind)

    sig
    |> Map.put(kind, Map.put(current, name, max(Map.get(current, name, -1), arity)))
  end

  # Collect `$o`-quantified variable names so a bare reference to one (a THF
  # `$o` variable used as a formula) is emitted as the raw variable instead of
  # a `tptp.`-prefixed nullary predicate.
  defp collect_bool_vars({:forall, vars, body}, acc),
    do: collect_bool_vars(body, add_o_vars(vars, acc))

  defp collect_bool_vars({:exists, vars, body}, acc),
    do: collect_bool_vars(body, add_o_vars(vars, acc))

  defp collect_bool_vars({:not, f}, acc), do: collect_bool_vars(f, acc)

  defp collect_bool_vars({:bin, _, l, r}, acc),
    do: collect_bool_vars(r, collect_bool_vars(l, acc))

  defp collect_bool_vars(_, acc), do: acc

  defp add_o_vars(vars, acc) do
    Enum.reduce(vars, acc, fn
      {v, "$o"}, a -> MapSet.put(a, v)
      _, a -> a
    end)
  end
end
