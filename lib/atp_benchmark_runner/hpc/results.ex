defmodule AtpBenchmarkRunner.HPC.Results do
  @moduledoc """
  Collects remote benchmark result files and parses them into `Result` structs.
  """

  alias AtpBenchmarkRunner.{Result, Run, Store}
  alias AtpBenchmarkRunner.HPC.{Config, JobScript, RemoteFiles, Shell}

  @doc """
  Collects all remote result metadata/output files for a run.

  Reads all result files per prover via a single bulk SSH command instead of
  one SSH call per file, avoiding rate-limiting the SSH gateway.

  Retries with exponential backoff on transient SSH failures so results are
  eventually collected even when the SSH gateway is under load.

  ## Options

    * `:wait_for_job` - when `true` (default) and the run has SLURM job ids, the
      job state is polled (cheap `sacct`) while the job is still running and the
      expensive tar+SCP download is skipped until the job terminates. Runs
      without job ids (e.g. remote-discovered) always fall back to direct
      fetching. Set `false` to keep the old fetch-every-poll behavior.
  """
  @spec collect(HpcConnect.Session.t(), Run.t(), keyword()) :: [Result.t()]
  def collect(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    max_retries = Keyword.get(opts, :collect_max_retries, 30)
    retry_delay_ms = Keyword.get(opts, :collect_retry_delay_ms, 10_000)
    expected = expected_result_count(run, opts)
    forever? = Keyword.get(opts, :collect_retry_forever, false)
    wait_for_job = Keyword.get(opts, :wait_for_job, true)

    collect_with_retry(
      session,
      run,
      opts,
      max_retries,
      retry_delay_ms,
      expected,
      forever?,
      wait_for_job,
      0
    )
  end

  # The runner knows how many (prover x problem) results should exist. When an
  # expected count is given, collection keeps polling until that many result
  # files are present instead of grabbing the first partial directory (which
  # is what previously caused "only tableaux produced output" when collection
  # raced ahead of a still-running job).
  defp expected_result_count(%Run{} = run, opts) do
    case Keyword.get(opts, :expected_results) do
      count when is_integer(count) and count > 0 ->
        count

      _ ->
        problems = Enum.count(run.problems)
        provers = Enum.count(run.provers)
        if problems > 0 and provers > 0, do: problems * provers, else: nil
    end
  end

  defp collect_with_retry(
         session,
         run,
         opts,
         0,
         _delay,
         _expected,
         _forever,
         _wait_for_job,
         _prev_count
       ) do
    IO.puts("[Results] Max retries reached; returning partial results or empty")

    case try_collect(session, run, opts) do
      {:ok, results} ->
        results

      {:error, reason} ->
        IO.puts("[Results] Final collect attempt failed: #{truncate_text(reason, 240)}")
        []
    end
  end

  defp collect_with_retry(
         session,
         run,
         opts,
         retries_left,
         delay_ms,
         expected,
         forever?,
         wait_for_job,
         prev_count
       ) do
    # With `:wait_for_job` (default) do not re-download the whole results tar on
    # every poll while the SLURM job is still running. The download is the
    # expensive part and its contents only change as the job writes new results,
    # so poll the cheap sacct job state and fetch only once the job terminated.
    status = if wait_for_job, do: job_status(session, run), else: :unknown

    if status == :running do
      retry_note(
        "[Results]",
        "job still running; waiting for completion before fetching",
        retries_left,
        delay_ms,
        forever?
      )

      Process.sleep(delay_ms)

      collect_with_retry(
        session,
        run,
        opts,
        next_retry(retries_left, forever?),
        min(delay_ms * 2, 60_000),
        expected,
        forever?,
        wait_for_job,
        prev_count
      )
    else
      result = try_collect(session, run, opts)

      case result do
        {:ok, results} when results != [] ->
          if is_integer(expected) and length(results) < expected do
            # After the job terminated, a fetch returning the same count as the
            # previous one means the run is complete with what it produced (some
            # problems may legitimately yield no result file), so stop
            # re-downloading instead of looping forever.
            if status == :terminal and prev_count == length(results) do
              IO.puts(
                "[Results] Collected #{length(results)} results, stable after job " <>
                  "termination, assuming complete"
              )

              results
            else
              retry_note(
                "[Results]",
                "collected #{length(results)}/#{expected} results so far",
                retries_left,
                delay_ms,
                forever?
              )

              Process.sleep(delay_ms)

              collect_with_retry(
                session,
                run,
                opts,
                next_retry(retries_left, forever?),
                min(delay_ms * 2, 60_000),
                expected,
                forever?,
                wait_for_job,
                length(results)
              )
            end
          else
            results
          end

        {:ok, []} ->
          retry_note("[Results]", "no result files found yet", retries_left, delay_ms, forever?)
          Process.sleep(delay_ms)

          collect_with_retry(
            session,
            run,
            opts,
            next_retry(retries_left, forever?),
            min(delay_ms * 2, 60_000),
            expected,
            forever?,
            wait_for_job,
            prev_count
          )

        {:error, reason} ->
          retry_note("[Results]", "SSH error", retries_left, delay_ms, forever?, reason)
          Process.sleep(delay_ms)

          collect_with_retry(
            session,
            run,
            opts,
            next_retry(retries_left, forever?),
            min(delay_ms * 2, 60_000),
            expected,
            forever?,
            wait_for_job,
            prev_count
          )
      end
    end
  end

  # In "retry until success" mode the counter is never decremented, so the
  # collection keeps polling with exponential backoff until results arrive.
  defp next_retry(retries_left, true), do: retries_left
  defp next_retry(retries_left, false), do: retries_left - 1

  # Muted retry logging: a one-line note while many retries remain, the full
  # (potentially huge) reason/command dump only when about to give up.
  defp retry_note(label, kind, retries_left, delay_ms, forever?, detail \\ nil) do
    left =
      if forever? do
        "∞ (retrying until success)"
      else
        "#{retries_left} retries left"
      end

    detail_part =
      if not is_nil(detail) and (forever? or retries_left <= 2) do
        "; #{truncate_text(detail, 240)}"
      else
        ""
      end

    IO.puts("#{label} #{kind}#{detail_part}; #{left}, retrying in #{delay_ms}ms")
  end

  defp truncate_text(text, max) when is_binary(text) do
    if byte_size(text) > max, do: binary_part(text, 0, max) <> "…", else: text
  end

  defp truncate_text(text, _max), do: to_string(text)

  # Classifies whether a run's SLURM jobs are still active:
  #
  #   * `:running`  - at least one submitted job is not in a terminal state
  #   * `:terminal` - all submitted jobs reached a terminal state (or are gone
  #     from sacct, i.e. finished)
  #   * `:unknown`  - the run has no trackable job ids, or the query failed
  #
  # Runs without job ids (e.g. a minimal `%Run{}` reconstructed via remote
  # discovery) always report `:unknown`, so collection falls back to the
  # plain count-based retry instead of waiting forever.
  defp job_status(%HpcConnect.Session{} = session, %Run{} = run) do
    job_ids = run_job_ids(run)

    if job_ids == [] do
      :unknown
    else
      ids = Enum.join(job_ids, ",")

      command =
        "sacct -j #{ids} --noheader --format=JobID,State --parsable2 2>/dev/null | " <>
          "sed 's/\\x1b\\[[0-9;]*m//g' | grep -v '^$' | grep -v 'WARNING' | grep -v 'Path' | " <>
          "grep -v '!!!' | awk -F'|' '$1 ~ /^[0-9]+$/ {print $1, $2}'"

      try do
        session
        |> HpcConnect.connect!(command)
        |> String.trim()
        |> classify_job_output()
      rescue
        _ -> :unknown
      end
    end
  end

  defp run_job_ids(%Run{} = run) do
    run.submitted_jobs
    |> Map.values()
    |> Enum.map(&(Map.get(&1, :job_id) || Map.get(&1, "job_id")))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  # Pure classification of raw sacct output. Exposed (doc false) for unit
  # testing without an SSH session.
  @doc false
  @spec classify_job_output(binary()) :: :running | :terminal
  def classify_job_output(""), do: :terminal

  def classify_job_output(output) do
    states =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r{\s+}, parts: 2) do
          [_job_id, state] -> [Config.terminal_state?(String.trim(state))]
          _ -> []
        end
      end)

    cond do
      states == [] -> :terminal
      Enum.all?(states) -> :terminal
      true -> :running
    end
  end

  defp try_collect(session, run, opts) do
    paths = remote_paths(run, session, opts)

    IO.puts("[Results] Looking for results in: #{paths.results_dir}")

    # Single bulk call: directory listing + result-file presence check. The marker
    # stays underscore-only because shell metacharacters (`<<<` is a here-string
    # operator) would kill the persistent shell.
    marker = "__HPC_RESULTS_CHECK__"

    bulk =
      HpcConnect.connect!(
        session,
        "ls -la #{Shell.quote(paths.results_dir)} 2>/dev/null || echo 'DIR_NOT_FOUND'; " <>
          "echo #{marker}; " <>
          "find #{Shell.quote(paths.results_dir)} \\( -name '*.out' -o -name '*.meta.json' \\) 2>/dev/null | head -5"
      )

    {diag, check} = split_on_marker(bulk, marker)

    IO.puts("[Results] ls output: #{String.slice(String.trim(diag), 0, 500)}")

    if String.trim(check) == "" do
      IO.puts("[Results] No result files found (empty directories)")
      {:ok, []}
    else
      IO.puts("[Results] Found result files; downloading via tar+SCP")
      collect_via_tar(session, paths.results_dir, run, opts)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp split_on_marker(bulk, marker) do
    case String.split(bulk, marker, parts: 2) do
      [before, after_marker] -> {before, after_marker}
      [before] -> {before, ""}
    end
  end

  # Tar the results directory on the cluster, SCP it back, extract locally
  defp collect_via_tar(session, results_dir, %Run{} = run, opts) do
    local_tmp = local_tmp_dir(opts)
    local_tar = Path.join(local_tmp, "results_#{run.id}.tar.gz")
    File.mkdir_p!(local_tmp)

    parent = posix_dirname(results_dir)
    dirname = posix_basename(results_dir)
    remote_tar = posix_join(parent, "results_#{run.id}.tar.gz")

    # Step 1: create the tar (unless already present from a previous retry) in a
    # single SSH call.
    tar_status =
      HpcConnect.connect!(
        session,
        "if [ ! -f #{Shell.quote(remote_tar)} ]; then " <>
          "cd #{Shell.quote(parent)} && tar czf #{Shell.quote(remote_tar)} #{Shell.quote(dirname)} 2>/dev/null " <>
          "&& echo CREATED || echo FAILED; " <>
          "else echo EXISTS; fi",
        Keyword.get(opts, :connect_opts, [])
      )
      |> String.trim()

    IO.puts("[Results] Tar status: #{tar_status}")

    if tar_status == "FAILED" do
      IO.puts("[Results] Tar creation failed (possible empty/absent results dir)")
    end

    # Step 2: download via SCP with its own retry + backoff
    IO.puts("[Results] Downloading to: #{local_tar}")

    case scp_download_with_retry(session, remote_tar, local_tar, opts) do
      :ok ->
        # Step 3: clean up remote tar (best-effort)
        HpcConnect.connect!(
          session,
          "rm -f #{Shell.quote(remote_tar)}",
          Keyword.get(opts, :connect_opts, [])
        )

        # Step 4: extract and parse locally
        results = extract_and_parse(local_tar, run, opts)
        File.rm_rf!(local_tar)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SCP download with its own independent retry + exponential backoff
  defp scp_download_with_retry(
         session,
         remote_path,
         local_path,
         opts,
         retries \\ 10,
         delay_ms \\ 5_000
       )

  defp scp_download_with_retry(_session, _remote_path, _local_path, _opts, 0, _delay) do
    {:error, "scp failed after all retries"}
  end

  defp scp_download_with_retry(session, remote_path, local_path, opts, retries_left, delay_ms) do
    case do_scp_download(session, remote_path, local_path) do
      :ok ->
        :ok

      {:error, reason} ->
        retry_note("[Results]", "SCP failed", retries_left, delay_ms, reason)

        Process.sleep(delay_ms)

        scp_download_with_retry(
          session,
          remote_path,
          local_path,
          opts,
          retries_left - 1,
          min(delay_ms * 2, 60_000)
        )
    end
  end

  defp do_scp_download(%HpcConnect.Session{} = session, remote_path, local_path) do
    scp_bin = System.find_executable("scp") || "scp"
    target = scp_target(session)

    if session.extended_debug do
      IO.puts("[hpc-ext-debug] scp: #{target}:#{remote_path} → #{local_path}")
    end

    # Remove existing local file so a fresh download doesn't merge with a stale partial
    File.rm_rf!(local_path)

    args =
      scp_option_args(session) ++
        ["#{target}:#{remote_path}", local_path]

    {output, status} = System.cmd(scp_bin, args, stderr_to_stdout: true)

    if status != 0 do
      {:error, output}
    else
      :ok
    end
  end

  defp scp_target(%{ssh_alias: alias}) when is_binary(alias) and alias != "", do: alias

  defp scp_target(%{username: username, cluster: %{host: host}})
       when is_binary(username) and is_binary(host) do
    "#{username}@#{host}"
  end

  defp scp_target(%{cluster: %{host: host}}) when is_binary(host), do: host

  defp scp_option_args(session) do
    proxy_jump = scp_proxy_jump(session)

    base =
      []
      |> maybe_append("-F", session.ssh_config_file)
      |> maybe_append("-J", proxy_jump)
      |> maybe_append("-i", session.identity_file)

    base ++
      [
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "PasswordAuthentication=no",
        "-o",
        "PreferredAuthentications=publickey",
        "-o",
        "NumberOfPasswordPrompts=0",
        "-o",
        "ConnectTimeout=30"
      ]
  end

  defp scp_proxy_jump(%{credential_dir: cd, ssh_config_file: f})
       when is_binary(f) and f != "" and is_binary(cd) and cd != "" do
    nil
  end

  defp scp_proxy_jump(%{proxy_jump: pj, username: u})
       when is_binary(pj) and pj != "" and is_binary(u) and u != "" do
    if String.contains?(pj, "@"), do: pj, else: "#{u}@#{pj}"
  end

  defp scp_proxy_jump(%{proxy_jump: pj}) when is_binary(pj) and pj != "" do
    if String.contains?(pj, "@"), do: pj, else: nil
  end

  defp scp_proxy_jump(_), do: nil

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, _flag, ""), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]

  defp extract_and_parse(tar_path, %Run{} = run, opts) do
    extract_dir = local_extract_dir(tar_path)
    File.rm_rf!(extract_dir)
    File.mkdir_p!(extract_dir)

    {_output, 0} = System.cmd("tar", ["xzf", tar_path, "-C", extract_dir])

    collected_at = Keyword.get(opts, :collected_at, timestamp())
    problem_names = Map.new(run.problems, &{&1.id, &1.name})

    # Find all prover subdirectories in the extracted tree
    # The tar was created from the parent dir of results_dir,
    # so the extracted tree starts with the results dirname
    results =
      extract_dir
      |> File.ls!()
      |> Enum.find(fn name -> File.dir?(Path.join(extract_dir, name)) end)
      |> case do
        nil ->
          IO.puts("[Results] Extracted dir empty or not found")
          []

        top_dir ->
          top_path = Path.join(extract_dir, top_dir)

          top_path
          |> File.ls!()
          |> Enum.filter(&File.dir?(Path.join(top_path, &1)))
          |> Enum.flat_map(fn prover_name ->
            prover_path = Path.join(top_path, prover_name)
            parse_prover_dir(prover_name, prover_path, problem_names, collected_at, run.id)
          end)
      end

    File.rm_rf!(extract_dir)
    results
  end

  defp local_tmp_dir(opts) do
    Keyword.get(opts, :local_tmp_dir) ||
      Path.join(System.tmp_dir!(), "atp_benchmark_runner_results")
  end

  defp local_extract_dir(tar_path), do: tar_path <> "_extracted"

  defp parse_prover_dir(prover_name, dir, problem_names, collected_at, run_id) do
    prover_atom =
      if is_binary(prover_name), do: String.to_atom(prover_name), else: prover_name

    dir
    |> File.ls!()
    |> Enum.group_by(
      fn name ->
        name |> String.replace_suffix(".out", "") |> String.replace_suffix(".meta.json", "")
      end,
      fn name ->
        content = File.read!(Path.join(dir, name))

        cond do
          String.ends_with?(name, ".meta.json") -> {:meta, content}
          String.ends_with?(name, ".out") -> {:output, content}
          true -> {:other, name, content}
        end
      end
    )
    |> Enum.map(fn {problem_id, files} ->
      output_content =
        Enum.find_value(files, fn
          {:output, content} -> content
          _ -> nil
        end) || ""

      meta =
        Enum.find_value(files, fn
          {:meta, content} -> Jason.decode!(content)
          _ -> nil
        end)

      result_attrs = %{
        run_id: run_id,
        collected_at: collected_at,
        problem_id: problem_id,
        problem_name: Map.get(problem_names, problem_id),
        prover: Atom.to_string(prover_atom),
        exit_status: if(meta, do: Map.get(meta, "exit_status")),
        wall_time_ms: if(meta, do: Map.get(meta, "wall_time_ms")),
        memory_kb: if(meta, do: Map.get(meta, "memory_kb")),
        output_path: nil,
        raw_output: output_content,
        metadata: %{
          missing_meta?: is_nil(meta),
          remote_resource_path: if(meta, do: Map.get(meta, "resource_path"))
        }
      }

      Result.from_output(
        Atom.to_string(prover_atom),
        problem_id,
        output_content,
        Map.to_list(result_attrs)
      )
    end)
  end

  @doc """
  Fallback per-file SSH-based collection (for backward compat / small result sets).
  """
  @spec collect_per_file(HpcConnect.Session.t(), Run.t(), keyword()) :: [Result.t()]
  def collect_per_file(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    paths = remote_paths(run, session, opts)
    collected_at = Keyword.get(opts, :collected_at, timestamp())

    opts =
      opts |> Keyword.put_new(:run_id, run.id) |> Keyword.put_new(:collected_at, collected_at)

    problem_names = Map.new(run.problems, &{&1.id, &1.name})

    run.provers
    |> Enum.flat_map(fn prover ->
      collect_for_prover(session, paths.results_dir, prover.name, problem_names, opts)
    end)
    |> Enum.sort_by(&{&1.problem_id, &1.prover})
  end

  @doc """
  Collects results and persists them in the local store.
  """
  @spec collect_and_store!(HpcConnect.Session.t(), Run.t(), keyword()) :: {binary(), [Result.t()]}
  def collect_and_store!(%HpcConnect.Session{} = session, %Run{} = run, opts \\ []) do
    results = collect(session, run, opts)
    {Store.save_results!(run, results, opts), results}
  end

  @doc """
  Finds a run's results directory on the remote cluster by run id and returns a
  minimal `%Run{}` (id + remote_root) that `collect/3` can use, or `nil`.

  Searches both the current `run_results/<id>` layout and the legacy `<id>`
  layout, across the config-resolved remote root and the session work/vault
  roots. Used as a fallback when a run has no local manifest (e.g. submitted
  before manifest persistence was added, or after a store wipe).
  """
  @spec find_remote_run(HpcConnect.Session.t(), binary(), keyword()) :: Run.t() | nil
  def find_remote_run(%HpcConnect.Session{} = session, run_id, opts \\ [])
      when is_binary(run_id) do
    root =
      Enum.find_value(candidate_roots(session, opts), fn root ->
        case Enum.find(run_dir_candidates(root, run_id), fn dir ->
               RemoteFiles.exists?(session, dir, opts)
             end) do
          nil -> nil
          _dir -> root
        end
      end)

    case root do
      nil ->
        nil

      root ->
        IO.puts("[collect] Found run #{run_id} on cluster under #{root}")
        minimal_run(run_id, root, safe_cluster(session, opts))
    end
  end

  @doc """
  Returns a minimal `%Run{}` for the newest run directory found on the remote
  cluster (current `run_results/` layout first, then legacy layout), or `nil`.
  """
  @spec latest_remote_run(HpcConnect.Session.t(), keyword()) :: Run.t() | nil
  def latest_remote_run(%HpcConnect.Session{} = session, opts \\ []) do
    case latest_run_dir(session, candidate_roots(session, opts), opts) do
      nil ->
        nil

      {root, dir} ->
        run_id = dir |> String.trim_trailing("/") |> Path.basename()
        IO.puts("[collect] Found newest cluster run #{run_id} (#{dir})")
        minimal_run(run_id, root, safe_cluster(session, opts))
    end
  end

  defp minimal_run(run_id, remote_root, cluster) do
    Run.new(
      id: run_id,
      cluster: cluster,
      remote_root: remote_root,
      problems: [],
      provers: []
    )
  end

  # Roots where runs may live: the config-resolved remote root, plus the
  # session work/vault-derived roots (the vault env var may be unset remotely).
  defp candidate_roots(session, opts) do
    config_root = safe_remote_root(session, opts)
    work_root = if session.work_dir, do: posix_join(session.work_dir, "atp_benchmark_runner")
    vault_root = if session.vault_dir, do: posix_join(session.vault_dir, "atp_benchmark_runner")

    [config_root, work_root, vault_root]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Config.resolve needs a real HPC session (cluster struct); for fake/partial
  # sessions (e.g. unit tests) the remote root is simply unknown.
  defp safe_remote_root(session, opts) do
    try do
      Config.resolve(session, opts).remote_root
    rescue
      _ -> nil
    end
  end

  defp safe_cluster(session, opts) do
    try do
      Config.resolve(session, opts).cluster
    rescue
      _ -> nil
    end
  end

  defp run_dir_candidates(root, run_id) do
    [posix_join(posix_join(root, "run_results"), run_id), posix_join(root, run_id)]
  end

  defp latest_run_dir(session, roots, opts) do
    roots
    |> Enum.flat_map(fn root ->
      cmd =
        "(ls -d #{Shell.quote(posix_join(root, "run_results"))}/run_* 2>/dev/null; " <>
          "ls -d #{Shell.quote(root)}/run_* 2>/dev/null) | sort -r"

      session
      |> HpcConnect.connect!(cmd, Keyword.get(opts, :connect_opts, []))
      |> String.split("\n", trim: true)
      |> Enum.map(&{root, String.trim(&1)})
    end)
    |> Enum.reject(fn {_root, dir} -> dir == "" end)
    |> Enum.sort_by(fn {_root, dir} -> dir end, :desc)
    |> List.first()
  end

  defp collect_for_prover(session, results_dir, prover_name, problem_names, opts) do
    dir = posix_join(results_dir, Atom.to_string(prover_name))
    meta_files = RemoteFiles.list(session, dir, "*.meta.json", opts)

    if meta_files == [] do
      session
      |> RemoteFiles.list(dir, "*.out", opts)
      |> Enum.map(&result_from_output_file(session, prover_name, &1, problem_names, opts))
    else
      Enum.map(meta_files, &result_from_meta_file(session, prover_name, &1, problem_names, opts))
    end
  end

  defp result_from_meta_file(session, prover_name, meta_path, problem_names, opts) do
    meta = session |> RemoteFiles.read_text!(meta_path, opts) |> Jason.decode!()
    output_path = Map.fetch!(meta, "output_path")
    output = RemoteFiles.read_text!(session, output_path, opts)
    problem_id = Map.fetch!(meta, "problem_id")

    result_attrs = %{
      run_id: Keyword.get(opts, :run_id),
      collected_at: Keyword.get(opts, :collected_at),
      problem_id: problem_id,
      problem_name: Map.get(problem_names, problem_id),
      prover: Map.get(meta, "prover", Atom.to_string(prover_name)),
      exit_status: Map.get(meta, "exit_status"),
      wall_time_ms: Map.get(meta, "wall_time_ms"),
      memory_kb: Map.get(meta, "memory_kb"),
      output_path: output_path,
      raw_output: maybe_raw_output(output, opts),
      metadata: %{
        remote_meta_path: meta_path,
        remote_resource_path: Map.get(meta, "resource_path")
      }
    }

    Result.from_output(prover_name, result_attrs.problem_id, output, Map.to_list(result_attrs))
  end

  defp result_from_output_file(session, prover_name, output_path, problem_names, opts) do
    output = RemoteFiles.read_text!(session, output_path, opts)
    problem_id = output_path |> Path.basename() |> String.replace_suffix(".out", "")

    Result.from_output(prover_name, problem_id, output,
      run_id: Keyword.get(opts, :run_id),
      collected_at: Keyword.get(opts, :collected_at),
      problem_name: Map.get(problem_names, problem_id),
      output_path: output_path,
      raw_output: maybe_raw_output(output, opts),
      metadata: %{remote_output_path: output_path, missing_meta?: true}
    )
  end

  defp maybe_raw_output(output, opts) do
    if Keyword.get(opts, :include_raw_output, false), do: output, else: nil
  end

  defp remote_paths(%Run{remote_root: root} = run, _session, _opts)
       when is_binary(root) and root != "" do
    JobScript.remote_paths(run, root)
  end

  defp remote_paths(%Run{} = run, session, opts) do
    root =
      Keyword.get(
        opts,
        :remote_root,
        posix_join(session.vault_dir || session.work_dir, "atp_benchmark_runner")
      )

    JobScript.remote_paths(run, root)
  end

  defp posix_join(left, right),
    do: Enum.join([String.trim_trailing(left, "/"), String.trim_leading(right, "/")], "/")

  defp posix_dirname(path) do
    path
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> Enum.drop(-1)
    |> case do
      [] -> if(String.starts_with?(path, "/"), do: "/", else: ".")
      parts -> "/" <> Enum.join(parts, "/")
    end
  end

  defp posix_basename(path) do
    path
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> List.last() || path
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
