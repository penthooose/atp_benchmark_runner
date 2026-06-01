defmodule AtpBenchmarkRunner.TPTP.Index do
  @moduledoc """
  Local TPTP file discovery, metadata loading, and filtering.
  """

  alias AtpBenchmarkRunner.Problem

  @logic_by_separator %{
    "^" => "THF",
    "_" => "TFF",
    "=" => "TFF",
    "+" => "FOF",
    "-" => "CNF"
  }

  @doc """
  Detects the actual TPTP library root below a configured directory.
  """
  @spec library_root(binary()) :: binary()
  def library_root(root_dir) when is_binary(root_dir) do
    root_dir = Path.expand(root_dir)

    cond do
      File.dir?(Path.join(root_dir, "Problems")) ->
        root_dir

      detected = detect_versioned_root(root_dir) ->
        detected

      true ->
        root_dir
    end
  end

  @doc """
  Lists local TPTP problem/axiom files.
  """
  @spec list_files(keyword()) :: [binary()]
  def list_files(opts) do
    root = opts |> Keyword.fetch!(:root_dir) |> library_root()

    include_axioms? =
      Keyword.get(opts, :include_axioms?, Keyword.get(opts, :include_axioms, true))

    root
    |> patterns(include_axioms?)
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&path_selected?(&1, opts))
    |> Enum.sort()
  end

  @doc """
  Loads local TPTP files as `AtpBenchmarkRunner.Problem` structs.
  """
  @spec load(keyword()) :: [Problem.t()]
  def load(opts) do
    root = opts |> Keyword.fetch!(:root_dir) |> library_root()
    limit = Keyword.get(opts, :limit)

    opts
    |> list_files()
    |> Enum.map(&problem_from_file(&1, root))
    |> Enum.filter(&problem_selected?(&1, opts))
    |> maybe_take(limit)
  end

  @doc """
  Returns a compact summary of loaded problems.
  """
  @spec summary([Problem.t()]) :: map()
  def summary(problems) when is_list(problems) do
    %{
      count: length(problems),
      by_logic: count_by(problems, &(&1.logic || "Unknown")),
      by_domain: count_by(problems, &(&1.domain || "Unknown")),
      with_rating: Enum.count(problems, &is_number(&1.rating))
    }
  end

  @doc """
  Infers the TPTP logic/form from the file name.
  """
  @spec logic_from_name(binary()) :: binary() | nil
  def logic_from_name(name) when is_binary(name) do
    case Regex.run(~r/^[A-Z]{3}\d{3}([\^_=+\-])/, Path.basename(name)) do
      [_, separator] -> Map.fetch!(@logic_by_separator, separator)
      _ -> nil
    end
  end

  @doc """
  Infers the three-letter TPTP domain from the file name.
  """
  @spec domain_from_name(binary()) :: binary() | nil
  def domain_from_name(name) when is_binary(name) do
    case Regex.run(~r/^([A-Z]{3})\d{3}/, Path.basename(name)) do
      [_, domain] -> domain
      _ -> nil
    end
  end

  defp detect_versioned_root(root_dir) do
    root_dir
    |> Path.join("TPTP-v*")
    |> Path.wildcard()
    |> Enum.filter(&(File.dir?(&1) and File.dir?(Path.join(&1, "Problems"))))
    |> Enum.sort()
    |> List.last()
  end

  defp patterns(root, include_axioms?) do
    if File.dir?(Path.join(root, "Problems")) do
      [Path.join([root, "Problems", "**", "*.p"])] ++
        if include_axioms?, do: [Path.join([root, "Axioms", "**", "*.ax"])], else: []
    else
      [Path.join([root, "**", "*.p"])] ++
        if include_axioms?, do: [Path.join([root, "**", "*.ax"])], else: []
    end
  end

  defp path_selected?(path, opts) do
    selected?(domain_from_name(path), normalized_values(opts, [:domains, :domain])) and
      selected?(logic_from_name(path), normalized_values(opts, [:logics, :logic, :forms, :form]))
  end

  defp problem_selected?(%Problem{} = problem, opts) do
    status_values = normalized_values(opts, [:statuses, :status, :expected_statuses])
    rating_min = normalize_float(Keyword.get(opts, :rating_min))
    rating_max = normalize_float(Keyword.get(opts, :rating_max))

    selected?(problem.expected_status, status_values, &String.upcase/1) and
      rating_selected?(problem.rating, rating_min, rating_max)
  end

  defp problem_from_file(path, root) do
    metadata = %{
      file_kind: file_kind(path),
      relative_path: Path.relative_to(path, root),
      tptp_name: path |> Path.basename() |> strip_tptp_extension()
    }

    Problem.from_tptp_file(path,
      logic: logic_from_name(path),
      domain: domain_from_name(path),
      metadata: metadata
    )
  end

  defp file_kind(path) do
    case Path.extname(path) do
      ".ax" -> :axiom
      _ -> :problem
    end
  end

  defp strip_tptp_extension(name) do
    name
    |> String.replace_suffix(".p", "")
    |> String.replace_suffix(".ax", "")
  end

  defp rating_selected?(nil, nil, nil), do: true
  defp rating_selected?(nil, _min, _max), do: false

  defp rating_selected?(rating, min, max) do
    (is_nil(min) or rating >= min) and (is_nil(max) or rating <= max)
  end

  defp selected?(_value, []), do: true
  defp selected?(nil, _values), do: false
  defp selected?(value, values), do: value in values

  defp selected?(value, values, normalizer) do
    selected?(if(is_nil(value), do: nil, else: normalizer.(value)), values)
  end

  defp normalized_values(opts, keys) do
    keys
    |> Enum.find_value(&Keyword.get(opts, &1))
    |> List.wrap()
    |> Enum.flat_map(&split_value/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end

  defp split_value(value) when is_binary(value),
    do: String.split(value, [",", "\n", "\r"], trim: true)

  defp split_value(value) when is_atom(value), do: [Atom.to_string(value)]
  defp split_value(value), do: [to_string(value)]

  defp normalize_float(nil), do: nil
  defp normalize_float(""), do: nil
  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value / 1

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp maybe_take(items, nil), do: items
  defp maybe_take(items, limit) when is_integer(limit) and limit > 0, do: Enum.take(items, limit)
  defp maybe_take(items, _limit), do: items

  defp count_by(items, fun) do
    items
    |> Enum.frequencies_by(fun)
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Map.new()
  end
end
