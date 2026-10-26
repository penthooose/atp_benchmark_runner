defmodule AtpBenchmarkRunner.TPTP.Dialect do
  @moduledoc """
  Works out which TPTP dialect a problem is written in.

  The language of the parsed statements decides it, refined by the `% SPC :` form
  where the problem states one, since the SPC tells `TH0`/`TH1`/`THF` apart while
  the statements only say `thf`. A file counts as the richest language it uses.
  """

  alias Tptp.Diagnostic
  alias Tptp.Header

  # Richest first: a TH0 problem that includes first-order axioms is still THF.
  @precedence [:thf, :tff, :tcf, :fof, :cnf, :tpi]

  @type form :: :thf | :tff | :tcf | :fof | :cnf | :tpi | :empty

  @typedoc """
  `:form` is the language family (`TH0`/`TH1` both map to `:thf`), `:label` the
  name to store on `Problem.logic`, `:status` the declared SZS status.
  """
  @type t :: %{
          form: form(),
          label: binary(),
          languages: [atom()],
          spc: map() | nil,
          status: atom() | nil,
          diagnostics: [Diagnostic.t()],
          header: map()
        }

  @doc """
  Detects the dialect of a file, or returns `{:error, {:invalid | :unreadable,
  messages}}`.
  """
  @spec detect(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def detect(path, opts \\ []) do
    case Tptp.from_file(path, parse_options(opts)) do
      {:ok, file, diagnostics} ->
        from_file(file, diagnostics, opts)

      {:error, diagnostics} ->
        {:error, {:unreadable, messages(diagnostics)}}
    end
  end

  @doc "Detects the dialect of TPTP source text."
  @spec detect_string(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def detect_string(content, opts \\ []) when is_binary(content) do
    {:ok, file, diagnostics} = Tptp.from_string(content, parse_options(opts))
    from_file(file, diagnostics, opts)
  end

  @doc """
  True when `accepts` admits the dialect.

  `accepts` is `:all` or a list of forms; `TH0`/`TH1`/`THF` all denote `:thf`, so
  declaring `THF` also accepts a `TH0` problem.
  """
  @spec accepts?(:all | [atom() | binary()], t()) :: boolean()
  def accepts?(:all, %{form: form}), do: form != :empty

  def accepts?(accepts, %{form: form}) when is_list(accepts),
    do: form in normalize_accepts(accepts)

  def accepts?(_accepts, _dialect), do: false

  @doc """
  Normalises a prover's `accepts` declaration into dialect forms.

  Raises for a name that is not a TPTP language, so a typo in `prover.exs` fails
  at load time instead of silently skipping every problem.
  """
  @spec normalize_accepts(:all | [atom() | binary()]) :: :all | [form()]
  def normalize_accepts(:all), do: :all
  def normalize_accepts("all"), do: :all

  def normalize_accepts(accepts) when is_list(accepts) do
    accepts
    |> Enum.map(&accept_form!/1)
    |> Enum.uniq()
  end

  @doc """
  Maps a TPTP language or SPC form name to the dialect family.

      iex> AtpBenchmarkRunner.TPTP.Dialect.accept_form!("TH0")
      :thf
  """
  @spec accept_form!(atom() | binary()) :: form()
  def accept_form!(name) do
    case name |> to_string() |> String.upcase() do
      "THF" -> :thf
      "TH0" -> :thf
      "TH1" -> :thf
      "TFF" -> :tff
      "TCF" -> :tcf
      "FOF" -> :fof
      "CNF" -> :cnf
      "TPI" -> :tpi
      other -> raise ArgumentError, "not a TPTP language: #{inspect(other)}"
    end
  end

  @doc "Uppercased name of a dialect form, as stored on `Problem.logic`."
  @spec form_name(form()) :: binary()
  def form_name(form) when form in @precedence, do: form |> to_string() |> String.upcase()
  def form_name(:empty), do: "EMPTY"

  # Internals

  defp from_file(file, diagnostics, opts) do
    if Diagnostic.any_errors?(diagnostics) do
      {:error, {:invalid, messages(diagnostics)}}
    else
      {:ok, build(file, diagnostics, Keyword.get(opts, :path) || file.path)}
    end
  end

  defp build(file, diagnostics, path) do
    languages = languages(file)
    header = header(file, path)
    spc = header && Header.spc(header)

    %{
      form: richest(languages),
      label: label(languages, spc),
      languages: languages,
      spc: spc,
      status: header && Header.status(header),
      diagnostics: diagnostics,
      header: if(header, do: Header.to_map(header), else: %{})
    }
  end

  defp languages(file) do
    file
    |> Tptp.File.formulae()
    |> Enum.map(& &1.language)
    |> Enum.uniq()
  end

  defp richest([]), do: :empty

  defp richest(languages) do
    Enum.find(@precedence, :empty, &(&1 in languages))
  end

  # The SPC form is the finer-grained statement of intent (`TH0` vs `TH1`), so it
  # wins over the language family when the header carries one.
  defp label(_languages, %{form: form}) when is_binary(form) and form != "", do: form
  defp label(languages, _spc), do: languages |> richest() |> form_name()

  # A file without a header (a bare formula) is not an error here: the dialect
  # comes from the statements in that case.
  defp header(file, path) do
    case Header.from_string(file.source, parse_options(path: path)) do
      {:ok, header, _diagnostics} -> header
      {:error, _reason} -> nil
    end
  end

  defp parse_options(opts) do
    case Keyword.get(opts, :path) do
      nil -> []
      path -> [path: path]
    end
  end

  defp messages(diagnostics) do
    Enum.map(diagnostics, fn diagnostic ->
      "#{diagnostic.code}: #{diagnostic.message}"
    end)
  end
end
