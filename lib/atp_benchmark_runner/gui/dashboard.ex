defmodule AtpBenchmarkRunner.GUI.Dashboard do
  @moduledoc """
  Kino-based Livebook overlay for configuring and starting benchmark runs.

  The module is safe to load outside Livebook. When Kino is unavailable it
  returns a plain map with the same information, so local scripts and tests do
  not need a notebook runtime.
  """

  alias AtpBenchmarkRunner.{Prover, Run}
  alias AtpBenchmarkRunner.GUI.Cache
  alias AtpBenchmarkRunner.HPC.Submitter

  @doc """
  Returns true when Kino modules are available.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Kino) and Code.ensure_loaded?(Kino.Control)

  @doc """
  Renders a Livebook dashboard for a benchmark run.

  In Livebook, this creates a form plus status frame. Submitting the form builds
  a run manifest, saves it to the recovery cache, and optionally submits jobs if
  a valid `hpc_connect` session is passed and `dry_run: false` is selected.
  """
  @spec overlay(HpcConnect.Session.t() | nil, keyword()) :: map() | term()
  def overlay(session \\ nil, opts \\ []) do
    if available?() do
      render_kino_overlay(session, opts)
    else
      fallback_overlay(session, opts)
    end
  end

  @doc """
  Renders a static report view.
  """
  @spec report(map(), keyword()) :: map() | term()
  def report(report, opts \\ []) when is_map(report) do
    if available?() do
      markdown =
        Map.get(report, :markdown) || Map.get(report, "markdown") || inspect(report, pretty: true)

      kino_markdown(markdown)
    else
      %{kino?: false, report: report, cache_dir: Cache.cache_dir(opts)}
    end
  end

  @doc """
  Builds a run from dashboard form data. Public for tests and custom notebooks.
  """
  @spec run_from_form(map(), keyword()) :: Run.t()
  def run_from_form(data, opts \\ []) when is_map(data) do
    prover_names = selected_provers(data)
    problem_paths = problem_paths(data)

    Run.new(
      title: value(data, :title, "Livebook ATP benchmark"),
      cluster: value(data, :cluster, nil),
      partition: blank_to_nil(value(data, :partition, nil)),
      walltime: value(data, :walltime, "02:00:00"),
      problem_timeout_seconds: parse_int(value(data, :problem_timeout_seconds, 300), 300),
      max_parallel_jobs: parse_int(value(data, :max_parallel_jobs, 32), 32),
      remote_root: blank_to_nil(value(data, :remote_root, nil)),
      problems: problem_paths,
      provers: prover_names,
      metadata: %{
        created_from: :livebook_dashboard,
        cache_dir: Cache.cache_dir(opts),
        dry_run: parse_bool(value(data, :dry_run, true))
      }
    )
  end

  defp render_kino_overlay(session, opts) do
    form = dashboard_form(opts)
    frame = kino_frame()
    cache_dir = Cache.cache_dir(opts)

    kino_render(kino_markdown(intro_markdown(cache_dir)))
    kino_render(form)
    kino_render(frame)

    maybe_listen(form, fn event ->
      data = Map.get(event, :data) || Map.get(event, "data") || %{}
      run = run_from_form(data, opts)
      Cache.save_run!(run, opts)
      Cache.record_event!(run, %{event: "form_submitted"}, opts)

      result =
        if parse_bool(value(data, :dry_run, true)) or is_nil(session) do
          Submitter.plan(run, session || fake_session_for_plan(opts), opts)
        else
          Submitter.submit_run(session, run, opts)
        end

      render_submission_result(frame, result, cache_dir)
    end)

    %{kino?: true, form: form, frame: frame, cache_dir: cache_dir}
  rescue
    e ->
      %{
        kino?: false,
        error: Exception.message(e),
        fallback: fallback_overlay(session, opts)
      }
  end

  defp fallback_overlay(_session, opts) do
    %{
      kino?: false,
      cache_dir: Cache.cache_dir(opts),
      message:
        "Kino is not available. Use AtpBenchmarkRunner.new_run/1 and AtpBenchmarkRunner.submit/3 from a script or IEx."
    }
  end

  defp render_submission_result(frame, %Run{} = run, cache_dir) do
    kino_frame_render(
      frame,
      kino_markdown("""
      ## Submitted benchmark run

      - Run: `#{run.id}`
      - Status: `#{run.status}`
      - Cached at: `#{cache_dir}`
      - Jobs: `#{inspect(run.submitted_jobs)}`
      """)
    )
  end

  defp render_submission_result(
         frame,
         %{run: %Run{} = run, scripts: scripts, paths: paths},
         cache_dir
       ) do
    script_list =
      scripts
      |> Enum.map_join("\n", fn {prover, script} -> "- `#{prover}` → `#{script.path}`" end)

    kino_frame_render(
      frame,
      kino_markdown("""
      ## Dry-run benchmark plan

      - Run: `#{run.id}`
      - Remote run dir: `#{paths.run_dir}`
      - Cached at: `#{cache_dir}`

      ### Scripts

      #{script_list}
      """)
    )
  end

  defp dashboard_form(opts) do
    default_provers = Keyword.get(opts, :default_provers, [:tableaux, :vampire, :eprover, :cvc5])
    prover_options = Enum.map(Prover.builtins(), &{&1.label, Atom.to_string(&1.name)})

    fields = [
      title:
        kino_input(:text, "Run title",
          default: Keyword.get(opts, :title, "ATP nightly smoke run")
        ),
      cluster:
        kino_input(:text, "Cluster", default: to_string(Keyword.get(opts, :cluster, "fritz"))),
      partition:
        kino_input(:text, "Partition", default: to_string(Keyword.get(opts, :partition, ""))),
      remote_root:
        kino_input(:text, "Remote root (optional)",
          default: to_string(Keyword.get(opts, :remote_root, ""))
        ),
      problem_paths:
        kino_input(:textarea, "Problem paths / names (one per line)",
          default: Keyword.get(opts, :problem_paths, "")
        ),
      provers:
        kino_input(:checkbox_grid, "Provers",
          options: prover_options,
          default: Enum.map(default_provers, &Atom.to_string/1)
        ),
      problem_timeout_seconds:
        kino_input(:number, "Per-problem timeout (seconds)",
          default: Keyword.get(opts, :problem_timeout_seconds, 300)
        ),
      max_parallel_jobs:
        kino_input(:number, "Max parallel array tasks",
          default: Keyword.get(opts, :max_parallel_jobs, 32)
        ),
      walltime:
        kino_input(:text, "SLURM walltime", default: Keyword.get(opts, :walltime, "02:00:00")),
      dry_run:
        kino_input(:checkbox, "Dry run (do not submit)",
          default: Keyword.get(opts, :dry_run, true)
        )
    ]

    apply(Kino.Control, :form, [fields, [submit: "Start / plan benchmark"]])
  end

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

  defp intro_markdown(cache_dir) do
    """
    ## ATP Benchmark Runner

    Configure a prover comparison, save a recovery manifest, and submit SLURM job arrays through `hpc_connect`.

    Recovery cache: `#{cache_dir}`
    """
  end

  defp selected_provers(data) do
    data
    |> value(:provers, [])
    |> List.wrap()
    |> Enum.map(fn
      value when is_atom(value) -> value
      value when is_binary(value) -> Prover.builtin(value)
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> [:tableaux]
      provers -> Enum.map(provers, & &1.name)
    end
  end

  defp problem_paths(data) do
    data
    |> value(:problem_paths, "")
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp value(data, key, default) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key)) || default
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool(value) when value in ["true", "1", 1], do: true
  defp parse_bool(_), do: false

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # Used only for dry-run rendering outside a connected notebook. The struct
  # shape lets the planner compute paths without opening SSH.
  defp fake_session_for_plan(opts) do
    HpcConnect.new_session(Keyword.get(opts, :cluster, :fritz),
      username: Keyword.get(opts, :username, "preview"),
      work_dir: Keyword.get(opts, :work_dir, "$HOME/.cache/hpc_connect")
    )
  end
end
