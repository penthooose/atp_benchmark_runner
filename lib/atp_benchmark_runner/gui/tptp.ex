defmodule AtpBenchmarkRunner.GUI.TPTP do
  @moduledoc """
  Kino helpers for selecting and preparing TPTP problem sets.
  """

  alias AtpBenchmarkRunner.{Problem, Store, TPTP}
  alias AtpBenchmarkRunner.GUI.Cache

  @doc """
  Returns true when Kino modules are available.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Kino) and Code.ensure_loaded?(Kino.Control)

  @doc """
  Renders a Livebook panel for installing/downloading and selecting TPTP files.
  """
  @spec panel(keyword()) :: map() | term()
  def panel(opts \\ []) do
    if available?() do
      render_kino_panel(opts)
    else
      fallback_panel(opts)
    end
  end

  @doc """
  Executes the TPTP preparation/selection described by form data.
  """
  @spec selection_from_form(map(), keyword()) :: map()
  def selection_from_form(data, opts \\ []) when is_map(data) do
    root_dir = value(data, :tptp_root_dir, livebook_root(opts)) |> to_string() |> Path.expand()
    actions = install_or_download(data, root_dir, opts)

    problems =
      TPTP.load_problem_set(
        root_dir: root_dir,
        include_axioms?: parse_bool(value(data, :include_axioms, true)),
        logics: selected_values(data, :forms),
        domains: value(data, :domains, ""),
        status: value(data, :status, ""),
        rating_min: parse_float(value(data, :rating_min, "")),
        rating_max: parse_float(value(data, :rating_max, "")),
        limit: parse_int(value(data, :limit, 50), 50)
      )

    %{
      root_dir: root_dir,
      library_root: TPTP.library_root(root_dir: root_dir),
      archive: archive_map(TPTP.default_archive()),
      actions: actions,
      summary: TPTP.summarize(problems),
      problems: problems,
      problem_paths: Enum.map(problems, & &1.path)
    }
  end

  defp render_kino_panel(opts) do
    form = tptp_form(opts)
    frame = kino_frame()
    cache_dir = Cache.cache_dir(opts)

    kino_render(kino_markdown(intro_markdown(cache_dir)))
    kino_render(form)
    kino_render(frame)

    maybe_listen(form, fn event ->
      data = Map.get(event, :data) || Map.get(event, "data") || %{}
      selection = selection_from_form(data, opts)

      Store.save_snapshot!("tptp_selection", selection_snapshot(selection), dir: cache_dir)
      kino_frame_render(frame, kino_markdown(selection_markdown(selection)))
    end)

    %{kino?: true, form: form, frame: frame, cache_dir: cache_dir}
  rescue
    e ->
      %{kino?: false, error: Exception.message(e), fallback: fallback_panel(opts)}
  end

  defp fallback_panel(opts) do
    root_dir = TPTP.default_root(opts)

    %{
      kino?: false,
      root_dir: root_dir,
      library_root: TPTP.library_root(root_dir: root_dir),
      archives: Enum.map(TPTP.available_archives(), &archive_map/1),
      message:
        "Kino is not available. Use AtpBenchmarkRunner.install_tptp_examples!/1 and AtpBenchmarkRunner.load_tptp_problems/1 from a script or IEx."
    }
  end

  defp tptp_form(opts) do
    archive = TPTP.default_archive()

    fields = [
      tptp_root_dir: kino_input(:text, "TPTP root/cache directory", default: livebook_root(opts)),
      install_examples: kino_input(:checkbox, "Install bundled smoke examples", default: true),
      download_full_archive:
        kino_input(:checkbox, "Download official #{archive.archive_name} (#{archive.size})",
          default: false
        ),
      extract_archive: kino_input(:checkbox, "Extract archive after download", default: true),
      forms:
        kino_input(:checkbox_grid, "Forms",
          options: form_options(),
          default: ["THF", "TFF", "FOF", "CNF"]
        ),
      domains: kino_input(:textarea, "Domains (optional, comma/newline separated)", default: ""),
      status: kino_input(:text, "Expected SZS status filter (optional)", default: ""),
      rating_min: kino_input(:text, "Minimum rating (optional)", default: ""),
      rating_max: kino_input(:text, "Maximum rating (optional)", default: ""),
      include_axioms: kino_input(:checkbox, "Include .ax files", default: true),
      limit: kino_input(:number, "Max selected files", default: Keyword.get(opts, :limit, 50))
    ]

    apply(Kino.Control, :form, [fields, [submit: "Prepare / select TPTP problems"]])
  end

  defp install_or_download(data, root_dir, opts) do
    []
    |> maybe_install_examples(data, root_dir)
    |> maybe_download_archive(data, root_dir, opts)
    |> Enum.reverse()
  end

  defp maybe_install_examples(actions, data, root_dir) do
    if parse_bool(value(data, :install_examples, true)) do
      paths = TPTP.install_examples!(root_dir: root_dir)

      destination =
        if paths == [], do: Path.join(root_dir, "bundled_examples"), else: Path.dirname(hd(paths))

      [
        %{action: :install_examples, count: length(paths), destination: destination}
        | actions
      ]
    else
      actions
    end
  end

  defp maybe_download_archive(actions, data, root_dir, opts) do
    if parse_bool(value(data, :download_full_archive, false)) do
      download_opts = Keyword.merge(opts, root_dir: root_dir)

      result =
        if parse_bool(value(data, :extract_archive, true)) do
          TPTP.ensure_archive(download_opts)
        else
          TPTP.download_archive(download_opts)
        end

      [%{action: :download_archive, result: normalize_result(result)} | actions]
    else
      actions
    end
  end

  defp normalize_result({:ok, path}), do: %{ok: true, path: path}
  defp normalize_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp normalize_result(other), do: %{ok: false, error: inspect(other)}

  defp selection_snapshot(selection) do
    %{
      root_dir: selection.root_dir,
      library_root: selection.library_root,
      archive: selection.archive,
      actions: selection.actions,
      summary: selection.summary,
      problems: Enum.map(selection.problems, &Problem.to_map/1)
    }
  end

  defp selection_markdown(selection) do
    preview =
      selection.problem_paths
      |> Enum.take(20)
      |> Enum.map_join("\n", &"- `#{&1}`")

    """
    ## TPTP selection ready

    - Root: `#{selection.root_dir}`
    - Library root: `#{selection.library_root}`
    - Problems selected: `#{selection.summary.count}`
    - With rating metadata: `#{selection.summary.with_rating}`

    ### By logic

    #{inspect(selection.summary.by_logic, pretty: true)}

    ### Preview

    #{if preview == "", do: "No files matched the current filters.", else: preview}
    """
  end

  defp intro_markdown(cache_dir) do
    archive = TPTP.default_archive()

    """
    ## TPTP problem preparation

    Select local/bundled TPTP files or explicitly download the official full archive.
    The official archive is `#{archive.archive_name}` (#{archive.size}, expands to #{archive.expands_to}), so it is **not** downloaded unless selected.

    Livebook recovery cache: `#{cache_dir}`
    """
  end

  defp livebook_root(opts) do
    Keyword.get(opts, :tptp_dir) ||
      Path.join(Cache.cache_dir(opts), "tptp")
  end

  defp archive_map(archive) do
    archive
    |> Map.from_struct()
    |> Map.update!(:components, &Enum.map(&1, fn component -> Atom.to_string(component) end))
  end

  defp form_options, do: Enum.map(["THF", "TFF", "FOF", "CNF"], &{&1, &1})

  defp kino_input(kind, label, opts) do
    input = Module.concat(Kino, Input)

    case kind do
      :textarea -> apply(input, :textarea, [label, opts])
      :checkbox_grid -> apply(input, :checkbox_grid, [label, opts])
      :checkbox -> apply(input, :checkbox, [label, opts])
      :number -> apply(input, :number, [label, opts])
      :text -> apply(input, :text, [label, opts])
    end
  end

  defp kino_markdown(markdown), do: apply(Module.concat(Kino, Markdown), :new, [markdown])
  defp kino_frame, do: apply(Module.concat(Kino, Frame), :new, [])
  defp kino_render(term), do: apply(Kino, :render, [term])

  defp kino_frame_render(frame, term),
    do: apply(Module.concat(Kino, Frame), :render, [frame, term])

  defp maybe_listen(form, fun) do
    if function_exported?(Kino, :listen, 2) do
      apply(Kino, :listen, [form, fun])
    else
      :ok
    end
  end

  defp value(data, key, default) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key)) || default
  end

  defp selected_values(data, key) do
    data
    |> value(key, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool(value) when value in ["true", "1", 1], do: true
  defp parse_bool(_), do: false

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value / 1
  defp parse_float(value) when value in [nil, ""], do: nil

  defp parse_float(value) do
    case Float.parse(to_string(value)) do
      {float, _} -> float
      :error -> nil
    end
  end
end
