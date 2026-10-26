defmodule AtpBenchmarkRunner.Problem do
  @moduledoc """
  A TPTP benchmark problem. Points to a local or remote path, or a name.

  Kept intentionally small; bulk metadata lives in the result store.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :path,
    :source,
    :logic,
    :rating,
    :expected_status,
    :domain,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          path: binary() | nil,
          source: :local | :remote | :tptp_name | :bundled | :downloaded | nil,
          logic: binary() | nil,
          rating: float() | nil,
          expected_status: binary() | nil,
          domain: binary() | nil,
          metadata: map()
        }

  @doc """
  Builds a problem struct from a keyword list or map.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)
    path = Map.get(attrs, :path)
    name = Map.get(attrs, :name) || infer_name(path) || Map.fetch!(attrs, :id)
    id = Map.get(attrs, :id) || name

    %__MODULE__{
      id: to_string(id),
      name: to_string(name),
      path: path,
      source: Map.get(attrs, :source),
      logic: Map.get(attrs, :logic),
      rating: normalize_rating(Map.get(attrs, :rating)),
      expected_status: Map.get(attrs, :expected_status),
      domain: Map.get(attrs, :domain),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Creates a problem from a local or remote path.
  """
  @spec from_path(binary(), keyword()) :: t()
  def from_path(path, attrs \\ []) when is_binary(path) do
    attrs
    |> Keyword.put_new(:path, path)
    |> Keyword.put_new(:name, infer_name(path))
    |> Keyword.put_new(:source, :remote)
    |> new()
  end

  @doc """
  Reads a TPTP file and extracts header metadata (rating, status, etc).
  """
  @spec from_tptp_file(binary(), keyword()) :: t()
  def from_tptp_file(path, attrs \\ []) when is_binary(path) do
    header = path |> File.read!() |> parse_tptp_header()
    attrs = merge_header_attrs(header, attrs)

    problem =
      path
      |> from_path(attrs)
      |> Map.put(:source, Keyword.get(attrs, :source, :local))

    # The SPC header states the dialect precisely (TH0/TH1/THF), which the file
    # name cannot: the separator heuristic in `TPTP.Index` maps "+" to "FOF", so
    # THF001+0.p would otherwise be filed as first-order.
    case problem.metadata[:spc] do
      nil ->
        problem

      spc when is_binary(spc) ->
        prefix = spc |> String.split("_") |> List.first()

        if prefix && prefix != "" do
          %{problem | logic: prefix}
        else
          problem
        end
    end
  end

  @doc """
  Parses `% Key : value` metadata lines from a TPTP header.

  Uses `Tptp.Header`, which implements the rules the TPTP states (continuation
  lines, only the first colon dividing a line, a key written twice keeping its
  last value). Headers without the dashed rules that open a real TPTP file are
  still read by a lenient fallback, so hand-written examples keep their metadata.
  """
  @spec parse_tptp_header(binary()) :: map()
  def parse_tptp_header(content) when is_binary(content) do
    case Tptp.Header.from_string(content) do
      {:ok, header, _diagnostics} -> header_to_map(header)
      {:error, _reason} -> lenient_header(content)
    end
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = problem) do
    %{
      id: problem.id,
      name: problem.name,
      path: problem.path,
      source: problem.source,
      logic: problem.logic,
      rating: problem.rating,
      expected_status: problem.expected_status,
      domain: problem.domain,
      metadata: problem.metadata
    }
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(map), do: new(map)

  # Header to the map shape the rest of the runner expects.

  defp header_to_map(header) do
    spc = Tptp.Header.spc(header)

    %{}
    |> put_present(:expected_status, header |> Tptp.Header.status() |> status_name())
    |> put_present(:rating, header |> Tptp.Header.get("Rating") |> leading_rating())
    |> put_present(:logic, spc_form(spc) || syntax_word(Tptp.Header.get(header, "Syntax")))
    |> put_present(:domain, Tptp.Header.get(header, "Domain"))
    |> put_present(:name, Tptp.Header.get(header, "Name"))
    |> Map.put(:metadata, header_metadata(header, spc))
  end

  defp header_metadata(header, spc) do
    %{}
    |> put_present(:file, Tptp.Header.get(header, "File"))
    |> put_present(:spc, Tptp.Header.get(header, "SPC"))
    |> put_present(:description, Tptp.Header.get(header, "Problem"))
    |> put_present(:description, Tptp.Header.get(header, "Axioms"))
    |> put_present(:source_ref, Tptp.Header.get(header, "Source"))
    |> put_present(:spc_form, spc_form(spc))
    |> put_present(:spc_status, spc_status_name(spc))
  end

  defp status_name(nil), do: nil
  defp status_name(status), do: Tptp.Szs.Ontology.name(status)

  defp spc_form(%{form: form}) when is_binary(form) and form != "", do: form
  defp spc_form(_spc), do: nil

  defp spc_status_name(%{status: nil}), do: nil
  defp spc_status_name(%{status: status}), do: Tptp.Szs.Ontology.name(status)
  defp spc_status_name(_spc), do: nil

  defp syntax_word(nil), do: nil
  defp syntax_word(syntax), do: syntax |> String.split() |> List.first()

  defp leading_rating(nil), do: nil

  defp leading_rating(value) when is_binary(value) do
    case Regex.run(~r/^\s*([01](?:\.\d+)?)/, value) do
      [_, number] -> normalize_rating(number)
      _ -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Lenient fallback for headers without the dashed rules that open a real TPTP
  # file: hand-written examples and user-supplied problem files.
  defp lenient_header(content) do
    content
    |> String.split("\n")
    |> Enum.take_while(
      &(String.starts_with?(String.trim_leading(&1), "%") or String.trim(&1) == "")
    )
    |> Enum.reduce(%{}, &parse_header_line/2)
  end

  defp parse_header_line(line, acc) do
    with [key, value] <-
           Regex.run(~r/^%\s*([^:]+?)\s*:\s*(.+?)\s*$/, line, capture: :all_but_first),
         normalized_key <- normalize_header_key(key),
         true <- not is_nil(normalized_key) do
      put_header_value(acc, normalized_key, value)
    else
      _ -> acc
    end
  end

  defp put_header_value(acc, {:metadata, key}, value) do
    metadata = Map.get(acc, :metadata, %{})
    Map.put(acc, :metadata, Map.put(metadata, key, String.trim(value)))
  end

  defp put_header_value(acc, normalized_key, value) do
    Map.put(acc, normalized_key, normalize_header_value(normalized_key, value))
  end

  defp normalize_header_key(key) do
    case key |> String.trim() |> String.downcase() do
      "status" -> :expected_status
      "rating" -> :rating
      "syntax" -> :logic
      "domain" -> :domain
      "name" -> :name
      "file" -> {:metadata, :file}
      "problem" -> {:metadata, :description}
      "axioms" -> {:metadata, :description}
      "source" -> {:metadata, :source_ref}
      "spc" -> {:metadata, :spc}
      _ -> nil
    end
  end

  defp normalize_header_value(:rating, value), do: normalize_rating(value)
  defp normalize_header_value(_key, value), do: String.trim(value)

  defp normalize_rating(nil), do: nil
  defp normalize_rating(value) when is_float(value), do: value
  defp normalize_rating(value) when is_integer(value), do: value / 1

  defp normalize_rating(value) when is_binary(value) do
    case Regex.run(~r/[0-1](?:\.\d+)?/, value) do
      [number] ->
        String.to_float(if String.contains?(number, "."), do: number, else: number <> ".0")

      _ ->
        nil
    end
  end

  defp infer_name(nil), do: nil

  defp infer_name(path) when is_binary(path) do
    path
    |> Path.basename()
    |> String.replace_suffix(".p", "")
    |> String.replace_suffix(".ax", "")
  end

  defp merge_header_attrs(header, attrs) do
    Keyword.merge(Map.to_list(header), attrs, fn
      :metadata, header_metadata, attr_metadata -> Map.merge(header_metadata, attr_metadata)
      _key, _header_value, attr_value -> attr_value
    end)
  end

  defp known_key(key) do
    case key do
      "expected_status" -> :expected_status
      "rating" -> :rating
      "metadata" -> :metadata
      "source" -> :source
      "logic" -> :logic
      "domain" -> :domain
      "path" -> :path
      "name" -> :name
      "id" -> :id
      _unknown -> nil
    end
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case known_key(key) do
          nil -> acc
          known -> Map.put(acc, known, value)
        end
    end)
  end
end
