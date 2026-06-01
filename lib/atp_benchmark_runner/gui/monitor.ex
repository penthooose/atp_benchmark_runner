defmodule AtpBenchmarkRunner.GUI.Monitor do
  @moduledoc """
  Livebook/Kino rendering helpers for benchmark progress snapshots.

  The polling logic remains in `AtpBenchmarkRunner.Monitor`; this module only
  turns a snapshot into notebook-friendly markdown and tables. Outside Livebook
  it returns plain data so scripts and tests can use the same API.
  """

  alias AtpBenchmarkRunner.{Monitor, Run}

  @doc """
  Renders the latest monitor snapshot.

  Pass `snapshot: snapshot` in tests or notebooks that already polled progress.
  Otherwise the function polls `AtpBenchmarkRunner.Monitor` when a session and
  run are provided.
  """
  @spec panel(HpcConnect.Session.t() | nil, Run.t() | nil, keyword()) :: map() | term()
  def panel(session, run, opts \\ []) do
    snapshot = Keyword.get(opts, :snapshot) || maybe_poll(session, run, opts)
    markdown = progress_markdown(snapshot)
    rows = progress_rows(snapshot)

    if available?() do
      render(snapshot, markdown, rows)
    else
      %{kino?: false, snapshot: snapshot, markdown: markdown, rows: rows}
    end
  end

  @doc """
  Returns true when Kino modules needed for rendering are available.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Kino) and Code.ensure_loaded?(Kino.DataTable)

  @doc """
  Builds a concise markdown status view with textual progress bars.
  """
  @spec progress_markdown(map() | nil) :: binary()
  def progress_markdown(nil) do
    """
    ## ATP benchmark monitor

    No monitor snapshot is available yet. Provide a session and run, or pass an
    existing snapshot with `snapshot: ...`.
    """
  end

  def progress_markdown(snapshot) when is_map(snapshot) do
    progress = Map.get(snapshot, :progress, [])
    stuck_jobs = Map.get(snapshot, :stuck_jobs, [])
    status = Map.get(snapshot, :status, :unknown)
    polled_at = Map.get(snapshot, :polled_at, "not polled")

    progress_lines =
      progress
      |> Enum.map(fn row ->
        prover = Map.fetch!(row, :prover)
        completed = Map.fetch!(row, :completed)
        total = Map.fetch!(row, :total)
        pending = Map.fetch!(row, :pending)

        "- `#{prover}` #{bar(completed, total)} #{completed}/#{total} completed, #{pending} pending"
      end)
      |> empty_message("- No prover progress rows yet.")

    stuck_lines =
      stuck_jobs
      |> Enum.map(fn row ->
        job_id = Map.get(row, :job_id) || Map.get(row, "job_id") || "unknown"
        state = Map.get(row, :state) || Map.get(row, "state") || "unknown"

        "- `#{job_id}` (`#{state}`)"
      end)
      |> empty_message("- None detected.")

    """
    ## ATP benchmark monitor

    - Run: `#{Map.get(snapshot, :run_id, "unknown")}`
    - Status: `#{status}`
    - Last poll: `#{polled_at}`

    ### Progress

    #{progress_lines}

    ### Potentially stuck jobs

    #{stuck_lines}
    """
  end

  @doc """
  Converts a monitor snapshot into rows suitable for `Kino.DataTable`.
  """
  @spec progress_rows(map() | nil) :: [map()]
  def progress_rows(nil), do: []

  def progress_rows(snapshot) when is_map(snapshot) do
    Enum.map(Map.get(snapshot, :progress, []), fn row ->
      %{
        prover: Map.fetch!(row, :prover),
        total: Map.fetch!(row, :total),
        completed: Map.fetch!(row, :completed),
        pending: Map.fetch!(row, :pending),
        completion_rate: Float.round(Map.get(row, :completion_rate, 0.0), 3),
        output_files: Map.get(row, :output_files, 0),
        metadata_files: Map.get(row, :metadata_files, 0),
        result_dir: Map.get(row, :result_dir)
      }
    end)
  end

  defp maybe_poll(%HpcConnect.Session{} = session, %Run{} = run, opts),
    do: Monitor.poll(session, run, opts)

  defp maybe_poll(_session, _run, _opts), do: nil

  defp render(snapshot, markdown, rows) do
    kino_render(kino_markdown(markdown))
    kino_render(kino_table(rows))

    %{kino?: true, snapshot: snapshot, rows: rows}
  rescue
    e -> %{kino?: false, error: Exception.message(e), snapshot: snapshot, rows: rows}
  end

  defp bar(_completed, 0), do: "`[----------]`"

  defp bar(completed, total) do
    filled = (completed * 10) |> div(total) |> min(10)
    empty = 10 - filled

    "`[#{String.duplicate("█", filled)}#{String.duplicate("-", empty)}]`"
  end

  defp empty_message([], message), do: message
  defp empty_message(lines, _message), do: Enum.join(lines, "\n")

  defp kino_markdown(markdown), do: apply(Module.concat(Kino, Markdown), :new, [markdown])
  defp kino_table(rows), do: apply(Module.concat(Kino, DataTable), :new, [rows])
  defp kino_render(term), do: apply(Kino, :render, [term])
end
