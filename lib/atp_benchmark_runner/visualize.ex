defmodule AtpBenchmarkRunner.Visualize do
  @moduledoc """
  Mermaid-based visualizations for ATP results and reports.

  This is the visual companion to `AtpBenchmarkRunner.explain/1` and
  `AtpBenchmarkRunner.explain_full/1`. Every builder returns a **raw Mermaid
  diagram string** so the output can be embedded in a Livebook markdown cell,
  saved as an `.mmd` file, or rendered directly with `render/2` (a
  `Kino.Mermaid` inside Livebook, a fenced code block everywhere else).

  ## Why Mermaid instead of eflambe flame graphs?

  eflambe profiles the Erlang/Elixir VM. Our reference provers (E, Vampire,
  cvc5, Zipperposition, Leo2, Leo3, lash) run as **external OS processes** via
  Docker/Apptainer, so there is no BEAM to profile. Even `:tableaux` runs as a
  separate escript VM. Mermaid diagrams, by contrast, are generated purely from
  data the runner already records (statuses, wall times, parsed proof clauses),
  render natively in Livebook via `Kino.Mermaid`, and add no runtime dependency.
  The closest data-driven analogue of a flame graph — a wall-time bar chart per
  problem — is provided by `timeline/2`.

  ## Diagram types

    * `result/2` — one flowchart per `Result` (prover → problem → status → timing)
    * `proof/2` — proof dependency DAG for machine-readable refutations
      (E/Vampire-style TPTP clauses); pipeline fallback otherwise
    * `status_pie/2` — SZS status distribution (per prover or whole run)
    * `timeline/2` — wall-time bar chart across problems (flame-graph flavour)
    * `report/2` — aggregated run scoreboard

  Prefer the top-level `AtpBenchmarkRunner.visualize/2` /
  `AtpBenchmarkRunner.visualize_proof/2` entries, which render for the current
  environment automatically.
  """

  alias AtpBenchmarkRunner.Result
  alias AtpBenchmarkRunner.Visualize.Proof

  @doc """
  Renders a single result as a Mermaid flowchart:

  ```
  flowchart LR
    P["🛠 eprover"] --> B["GRP001-0"]
    B --> S["✅ Theorem"]
    S --> T["⏱ 812 ms · 💾 12.1 MB"]
  ```

  Solved results are tinted green, failed ones red.
  """
  @spec result(Result.t(), keyword()) :: binary()
  def result(%Result{} = r, _opts \\ []) do
    status = r.szs_status || "Unknown"
    solved = Result.solved?(r)
    cls = if solved, do: "solved", else: "failed"
    status_label = if solved, do: "✅ Solved", else: "❌ Failed"

    """
    flowchart LR
      P["🛠 #{escape_label(to_string(r.prover))}"] --> B["#{escape_label(r.problem_id)}"]
      B --> S["#{status_label} #{escape_label(status)}"]
      S --> T["⏱ #{format_duration(r.wall_time_ms)} · 💾 #{format_memory(r.memory_kb)}"]
      classDef solved fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
      classDef failed fill:#ffebee,stroke:#c62828,color:#b71c1c
      class P,B,S,T #{cls}
    """
    |> String.trim()
  end

  @doc """
  Renders the proof of a result as a Mermaid dependency DAG.

  When the proof is a machine-readable TPTP clause refutation (E/Vampire style),
  each step becomes a node and each `inference` dependency an edge; the step
  deriving `$false`/`$true` is highlighted as the root. Other proof formats
  fall back to a simple pipeline diagram that still shows status and proof size.

  ## Options

    * `:max_nodes` — cap on rendered steps to keep large proofs readable
      (default: 60). Extra steps are omitted with a note.
  """
  @spec proof(Result.t(), keyword()) :: binary()
  def proof(%Result{} = r, opts \\ []) do
    case Proof.parse(r) do
      {:ok, graph} -> proof_dag(r, graph, Keyword.get(opts, :max_nodes, 60))
      {:error, reason} -> pipeline(r, reason)
    end
  end

  @doc """
  Renders the SZS status distribution of a list of results as a Mermaid pie.

  Pass `prover: :eprover` to restrict the pie to a single prover.
  """
  @spec status_pie([Result.t()], keyword()) :: binary()
  def status_pie(results, opts \\ []) when is_list(results) do
    results = maybe_filter_prover(results, Keyword.get(opts, :prover))
    freqs = Enum.frequencies_by(results, &(&1.szs_status || "Unknown"))
    title = Keyword.get(opts, :title) || pie_title(results)

    slices =
      Enum.map_join(freqs, "\n", fn {status, count} ->
        "    \"#{escape_label(status)}\" : #{count}"
      end)

    """
    pie showData
      title #{escape_label(title)}
    #{slices}
    """
    |> String.trim()
  end

  @doc """
  Renders wall times as a Mermaid gantt (one section per problem, one bar per
  prover). This is the closest data-driven analogue of a flame graph for
  benchmark runs — it shows at a glance where wall time went.

  Pass `prover: :eprover` to chart a single prover. Bars are in whole seconds
  (mermaid gantt does not reliably render fractional seconds).
  """
  @spec timeline([Result.t()], keyword()) :: binary()
  def timeline(results, opts \\ []) when is_list(results) do
    results = maybe_filter_prover(results, Keyword.get(opts, :prover))
    title = Keyword.get(opts, :title) || "Wall time per problem (s)"

    sections =
      results
      |> Enum.group_by(& &1.problem_id)
      |> Enum.sort_by(fn {problem, _} -> problem end)
      |> Enum.map_join("\n", fn {problem, problem_results} ->
        bars =
          Enum.map_join(problem_results, "\n", fn r ->
            "    #{task_id(r.prover, problem)}, #{escape_label(to_string(r.prover))} : 0, #{seconds(r.wall_time_ms)}"
          end)

        "  section #{escape_label(problem)}\n#{bars}"
      end)

    """
    gantt
      dateFormat X
      axisFormat %S
      title #{escape_label(title)}
    #{sections}
    """
    |> String.trim()
  end

  @doc """
  Renders an aggregated report as a Mermaid scoreboard flowchart:

  ```
  flowchart LR
    TOT["Total: 112 results"] --> SOL["Solved: 87 (77.7%)"]
    SOL --> E["eprover: 12/14 (85.7%)"]
    ...
  ```
  """
  @spec report(map(), keyword()) :: binary()
  def report(%{totals: totals, by_prover: by_prover}, _opts \\ []) do
    prover_nodes =
      Enum.map_join(by_prover, "\n", fn row ->
        "  #{node_id(to_string(row.prover))}[\"#{escape_label(to_string(row.prover))}: " <>
          "#{row.solved}/#{row.total} (#{Float.round(row.solve_rate * 100, 1)}%)\"]"
      end)

    prover_edges =
      Enum.map_join(by_prover, "\n", fn row ->
        "  SOL --> #{node_id(to_string(row.prover))}"
      end)

    """
    flowchart LR
      TOT["Total: #{totals.total_results} results"] --> SOL["Solved: #{totals.solved_results} (#{Float.round(totals.solve_rate * 100, 1)}%)"]
    #{prover_edges}
    #{prover_nodes}
    """
    |> String.trim()
  end

  @doc """
  Wraps a diagram in a fenced `mermaid` markdown block for pasting into a
  Livebook markdown cell.
  """
  @spec markdown(binary()) :: binary()
  def markdown(diagram) when is_binary(diagram) do
    "```mermaid\n#{String.trim(diagram)}\n```\n"
  end

  @doc """
  Renders a diagram for the current environment.

  Returns a `Kino.Mermaid` when the Kino application is running (Livebook),
  otherwise a fenced markdown string (IEx, scripts, tests). `:caption` and
  `:download` options are forwarded to `Kino.Mermaid.new/2`.
  """
  @spec render(binary(), keyword()) :: term()
  def render(diagram, opts \\ []) when is_binary(diagram) do
    if kino_available?() do
      Kino.Mermaid.new(String.trim(diagram), opts)
    else
      markdown(diagram)
    end
  end

  @doc """
  True when a native Kino Mermaid renderer is available and the Kino
  application is running (i.e. inside Livebook).
  """
  @spec available?() :: boolean()
  def available?, do: kino_available?()

  # ── Proof DAG ─────────────────────────────────────────────────────────────

  defp proof_dag(_r, graph, max_nodes) do
    steps = graph.steps
    truncated? = length(steps) > max_nodes
    steps = if truncated?, do: Enum.take(steps, max_nodes), else: steps
    shown = MapSet.new(steps, & &1.name)
    root? = MapSet.member?(shown, graph.root)

    edges =
      Enum.filter(graph.edges, fn {a, b} ->
        MapSet.member?(shown, a) and MapSet.member?(shown, b)
      end)

    node_lines =
      Enum.map_join(steps, "\n", fn step ->
        "  #{node_id(step.name)}[\"#{escape_label("#{step.role}: #{step.clause}")}\"]"
      end)

    edge_lines = Enum.map_join(edges, "\n", fn {a, b} -> "  #{node_id(a)} --> #{node_id(b)}" end)

    root_line = if root?, do: "  class #{node_id(graph.root)} root", else: ""

    trunc_note =
      if truncated?,
        do:
          "  Note[\"#{escape_label("#{length(steps)} of #{length(graph.steps)} proof steps shown")}\"]\n",
        else: ""

    """
    flowchart LR
    #{trunc_note}#{node_lines}
    #{edge_lines}
    #{root_line}
      classDef root fill:#fff3cd,stroke:#f9a825,stroke-width:2px
    """
    |> String.trim()
  end

  # Fallback for proofs that are not machine-parseable (prose, LaTeX, ...).
  defp pipeline(r, _reason) do
    status = r.szs_status || "Unknown"
    solved = Result.solved?(r)
    status_label = if solved, do: "✅ Solved", else: "❌ Failed"
    proof = Result.extract_proof(r)
    proof_lines = if proof, do: proof |> String.split("\n") |> length(), else: 0

    proof_label =
      if proof, do: "#{proof_lines} proof lines (non-graph format)", else: "no proof block"

    """
    flowchart LR
      IN["Input: #{escape_label(r.problem_id)}"] --> PR["Prover: #{escape_label(to_string(r.prover))}"]
      PR --> ST["#{status_label} #{escape_label(status)}"]
      ST --> OUT["#{escape_label(proof_label)}"]
    """
    |> String.trim()
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp pie_title(results) do
    case results |> Enum.map(& &1.prover) |> Enum.uniq() do
      [prover] -> "SZS status distribution — #{prover}"
      _ -> "SZS status distribution (all provers)"
    end
  end

  defp maybe_filter_prover(results, nil), do: results
  defp maybe_filter_prover(results, prover), do: Enum.filter(results, &(&1.prover == prover))

  defp seconds(nil), do: 0
  defp seconds(ms) when ms <= 0, do: 0
  defp seconds(ms), do: max(1, round(ms / 1000))

  defp format_duration(nil), do: "N/A"
  defp format_duration(ms) when ms < 1000, do: "#{ms} ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 2)} s"

  defp format_memory(nil), do: "N/A"
  defp format_memory(kb) when kb < 1024, do: "#{kb} KB"
  defp format_memory(kb), do: "#{Float.round(kb / 1024, 1)} MB"

  # Mermaid quoted labels tolerate most characters but quotes and angle
  # brackets are risky; newlines would break the diagram.
  defp escape_label(text) when is_binary(text) do
    text
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace("\"", "'")
    |> String.replace("<", "(")
    |> String.replace(">", ")")
    |> String.trim()
  end

  defp node_id(name) do
    "n_" <> String.replace(name, ~r/[^A-Za-z0-9_]/, "_")
  end

  # Gantt task ids must be unique across the whole diagram; derive them from
  # prover + problem so the same prover can appear in several sections.
  defp task_id(prover, problem) do
    "t_" <> String.replace("#{prover}_#{problem}", ~r/[^A-Za-z0-9_]/, "_")
  end

  # Kino.JS (used by Kino.Mermaid) stores state in ETS and bridges to the
  # Livebook frontend, so it only works when the Kino application is running.
  defp kino_available? do
    Code.ensure_loaded?(Kino.Mermaid) and
      List.keymember?(Application.started_applications(), :kino, 0)
  end
end
