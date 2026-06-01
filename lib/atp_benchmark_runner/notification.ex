defmodule AtpBenchmarkRunner.Notification do
  @moduledoc """
  Notification boundary for benchmark completion summaries.

  Webhooks are sent directly with `Req`. Email delivery is intentionally kept as
  a host responsibility: this module writes a structured email-summary artifact
  that can be handed to system mail, Oban workers, or institutional tooling.
  """

  alias AtpBenchmarkRunner.{Report, Run, Store}

  @doc """
  Builds a JSON-friendly notification payload from a report.
  """
  @spec payload(map() | [map()], Run.t() | nil, keyword()) :: map()
  def payload(report_or_results, run \\ nil, opts \\ []) do
    report = normalize_report(report_or_results, run, opts)
    run_id = run_id(run, report)

    %{
      event: Keyword.get(opts, :event, "atp_benchmark.completed"),
      run_id: run_id,
      title: Keyword.get(opts, :title) || run_title(run),
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      totals: value(report, :totals, %{}),
      interesting: value(report, :interesting, %{}),
      markdown: value(report, :markdown, "")
    }
  end

  @doc """
  Sends a report payload to a webhook URL.

  The URL may be passed as `:webhook_url` or supplied through the
  `ATP_BENCHMARK_RUNNER_WEBHOOK_URL` environment variable.
  """
  @spec send_webhook(map() | [map()], Run.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def send_webhook(report_or_results, run \\ nil, opts \\ []) do
    with {:ok, url} <- webhook_url(opts),
         request = [url: url, json: payload(report_or_results, run, opts)],
         {:ok, response} <- Req.post(request) do
      {:ok, %{status: response.status, body: response.body}}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Writes an email-ready Markdown summary artifact and returns its path.
  """
  @spec write_email_summary!(map() | [map()], Run.t() | nil, keyword()) :: binary()
  def write_email_summary!(report_or_results, run \\ nil, opts \\ []) do
    report = normalize_report(report_or_results, run, opts)
    run_id = run_id(run, report) || "unknown"
    dir = Keyword.get(opts, :dir, Store.default_dir())
    File.mkdir_p!(dir)

    subject = Keyword.get(opts, :subject, "ATP benchmark #{run_id} completed")
    recipients = opts |> Keyword.get(:recipients, []) |> List.wrap() |> Enum.join(", ")
    path = Path.join(dir, "#{run_id}_email_summary.md")

    File.write!(path, email_markdown(subject, recipients, report))
    path
  end

  defp webhook_url(opts) do
    case Keyword.get(opts, :webhook_url) || System.get_env("ATP_BENCHMARK_RUNNER_WEBHOOK_URL") do
      nil -> {:error, :missing_webhook_url}
      "" -> {:error, :missing_webhook_url}
      url -> {:ok, url}
    end
  end

  defp normalize_report(%{totals: _} = report, _run, _opts), do: report

  defp normalize_report(results, %Run{} = run, opts) when is_list(results),
    do: Report.summarize(results, run, opts)

  defp normalize_report(results, nil, opts) when is_list(results),
    do: Report.summarize(results, nil, opts)

  defp normalize_report(report, _run, _opts) when is_map(report), do: report

  defp run_id(%Run{id: id}, _report), do: id
  defp run_id(_run, report), do: value(report, :run_id, nil)

  defp run_title(%Run{title: title}), do: title
  defp run_title(_run), do: nil

  defp value(map, key, default) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp email_markdown(subject, recipients, report) do
    """
    Subject: #{subject}
    To: #{recipients}

    #{value(report, :markdown, inspect(report, pretty: true))}
    """
  end
end
