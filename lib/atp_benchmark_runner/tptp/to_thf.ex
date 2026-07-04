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
    lines = String.split(content, "\n")
    {header, body} = split_header(lines)
    {sym, formulas} = process_formulas(body)
    types = generate_types(sym)

    ([update_spc(header), "", types, ""] ++ formulas)
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
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
  def ensure_thf(path, :lash, opts \\ []) do
    if needs_conversion?(path) do
      {out, _} = convert_file(path, opts)
      out
    else
      path
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
    Enum.reduce(lines, {%{prop: MapSet.new(), func: MapSet.new()}, []}, fn
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

  defp convert_formula(formula, sym) do
    apps = collect_apps(formula)
    vars = collect_vars(formula)
    bare = collect_bare(formula, apps, vars)

    new_sym =
      sym
      |> Map.update!(:func, &MapSet.union(&1, apps))
      |> Map.update!(:prop, &MapSet.union(&1, bare))
      |> Map.update!(:func, &MapSet.union(&1, bare))

    thf =
      formula
      |> String.replace(~r/\b(fof|cnf|tff)\(/, "thf(")
      |> annotate_quants()

    {new_sym, thf}
  end

  defp collect_apps(formula) do
    ~r/\b([a-z_][a-zA-Z0-9_]*)\s*\(/
    |> Regex.scan(formula)
    |> Enum.map(fn [_, n] -> n end)
    |> Enum.reject(&(&1 in @known))
    |> MapSet.new()
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

  defp collect_bare(formula, apps, vars) do
    ~r/\b([a-z_][a-zA-Z0-9_]*)\b/
    |> Regex.scan(formula)
    |> Enum.map(fn [_, w] -> w end)
    |> Enum.reject(&(&1 in @known))
    |> Enum.reject(&MapSet.member?(vars, &1))
    |> Enum.reject(&MapSet.member?(apps, &1))
    |> Enum.reject(&(String.length(&1) == 1 and &1 >= "a" and &1 <= "z"))
    |> MapSet.new()
  end

  # ── Type declarations ─────────────────────────────────────────────────────

  defp generate_types(symbols) do
    prop =
      symbols.prop
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn s -> "thf(tp_#{s}, type, (#{s}: $o))." end)

    func =
      symbols.func
      |> MapSet.difference(symbols.prop)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn s -> "thf(tp_#{s}, type, (#{s}: $i > $i > $i))." end)

    prop ++ func
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
