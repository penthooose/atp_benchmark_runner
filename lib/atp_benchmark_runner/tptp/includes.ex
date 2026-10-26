defmodule AtpBenchmarkRunner.TPTP.Includes do
  @moduledoc """
  Inlines `include` directives into one self-contained problem.

  Provers do not resolve `include`, so a problem that names axiom sets has to be
  inlined first; otherwise it is run without its axioms. `Tptp.Unit` reads the
  graph (one read per file, cycles cut) and `Tptp.Printer.Canonical` prints it,
  with the original `%` header kept so `% Status` and `% SPC` survive. An include
  that cannot be resolved is reported, never dropped.
  """

  alias Tptp.Diagnostic
  alias Tptp.Printer.Canonical
  alias Tptp.Resolver
  alias Tptp.Statement.Include
  alias Tptp.Unit

  alias AtpBenchmarkRunner.TPTP.Index

  # A cyclic include is cut by the library, so the problem would silently lose
  # content; a too-deep walk means the graph is not what it claims. Both are
  # errors here.
  @fatal_include_codes ["TPTP0601", "TPTP0602", "TPTP0605"]

  @doc "True when the file names at least one `include` directive."
  @spec includes?(Path.t()) :: boolean()
  def includes?(path) do
    case Tptp.from_file(path) do
      {:ok, file, _diagnostics} -> Tptp.File.includes(file) != []
      {:error, _diagnostics} -> false
    end
  end

  @doc "The include names a problem source text names, in source order."
  @spec directive_names(binary()) :: [binary()]
  def directive_names(content) when is_binary(content) do
    {:ok, file, _diagnostics} = Tptp.from_string(content)

    file
    |> Tptp.File.includes()
    |> Enum.map(&Include.path/1)
  end

  @doc """
  Expands the includes of `path`, writing a self-contained problem.

  Options: `:output_dir` (default: beside the original) and `:tptp_root` (default:
  the configured `TPTP_ROOT`). A problem without includes comes back unchanged.
  The expanded file is always rewritten, since its content depends on axiom files
  outside the problem.
  """
  @spec expand(Path.t(), keyword()) ::
          {:ok, %{path: binary(), expanded?: boolean(), files: [binary()]}}
          | {:error, term()}
  def expand(path, opts \\ []) do
    case Tptp.from_file(path) do
      {:error, diagnostics} ->
        {:error, {:unreadable, messages(diagnostics)}}

      {:ok, file, diagnostics} ->
        cond do
          Diagnostic.any_errors?(diagnostics) ->
            {:error, {:invalid_problem, messages(diagnostics)}}

          Tptp.File.includes(file) == [] ->
            {:ok, %{path: path, expanded?: false, files: [path]}}

          true ->
            write(file, path, opts)
        end
    end
  end

  @doc """
  Directories an include is resolved against, in order.

  A TPTP root can hold a partial flat tree next to a complete unpacked archive
  under `TPTP-v<version>/`; the archive goes first so a stray file cannot shadow a
  real axiom set. `Tptp.Resolver.Fs` still checks the including file's own
  directory before these.
  """
  @spec roots(binary() | [binary()] | nil) :: [binary()]
  def roots(nil), do: []
  def roots([]), do: []
  def roots(roots) when is_list(roots), do: roots |> Enum.flat_map(&roots/1) |> Enum.uniq()

  def roots(root) when is_binary(root) do
    [versioned(root), Index.library_root(root), Path.expand(root)]
    |> List.flatten()
    |> Enum.uniq()
  end

  defp versioned(root) do
    root
    |> Path.join("TPTP-v*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort(:desc)
  end

  @doc "Local path of an include name, or `nil` when it does not resolve."
  @spec resolve(binary(), Path.t() | nil, keyword()) :: Path.t() | nil
  def resolve(name, from_path, opts \\ []) do
    resolver = resolver(opts)

    case Resolver.resolve(resolver, name, from_path) do
      {:ok, path, _content} -> path
      _ -> nil
    end
  end

  @doc """
  Path the expanded copy is written to.

  Stable per source path, so repeated runs overwrite one file, and two same-named
  problems from different directories cannot collide.
  """
  @spec expanded_path(Path.t(), keyword()) :: Path.t()
  def expanded_path(path, opts \\ []) do
    dir = Keyword.get(opts, :output_dir) || Path.dirname(path)
    base = Path.basename(path) |> strip_extension()
    hash = path |> Path.expand() |> then(&:erlang.phash2/1) |> Integer.to_string(16)

    Path.join(dir, "#{base}_#{hash}_expanded.p")
  end

  # Internals

  defp write(file, path, opts) do
    case Unit.from_file(path, resolver: resolver(opts), max_concurrency: 1) do
      {:ok, unit, diagnostics} ->
        with :ok <- check_resolution(diagnostics) do
          target = expanded_path(path, opts)
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, header_prefix(file) <> Canonical.to_string(unit))

          {:ok, %{path: target, expanded?: true, files: read_paths(unit, path)}}
        end

      {:error, diagnostics} ->
        {:error, {:unparsable, messages(diagnostics)}}
    end
  end

  # Every file the expansion read, root first: the dependency set of the problem.
  defp read_paths(unit, path) do
    included =
      unit.files
      |> Map.values()
      |> Enum.map(& &1.path)
      |> Enum.reject(&is_nil/1)

    [path | included] |> Enum.uniq()
  end

  defp check_resolution(diagnostics) do
    unresolved =
      Enum.filter(diagnostics, fn diagnostic ->
        diagnostic.code in @fatal_include_codes or diagnostic.severity == :error
      end)

    case unresolved do
      [] -> :ok
      found -> {:error, {:include_unresolved, messages(found)}}
    end
  end

  # Everything before the first statement: the `%` header block, kept verbatim so
  # `% Status`, `% SPC` and `% Rating` stay readable downstream.
  defp header_prefix(%Tptp.File{source: source, statements: [first | _]}),
    do: binary_part(source, 0, first.off)

  defp header_prefix(%Tptp.File{source: source}), do: source

  defp strip_extension(name) do
    name
    |> String.replace_suffix(".p", "")
    |> String.replace_suffix(".tptp", "")
  end

  defp resolver(opts) do
    case roots(Keyword.get(opts, :tptp_root)) do
      [] -> Resolver.Fs
      roots -> {Resolver.Fs, root: roots}
    end
  end

  defp messages(diagnostics) do
    Enum.map(diagnostics, fn diagnostic ->
      "#{diagnostic.code}: #{diagnostic.message}"
    end)
  end
end
