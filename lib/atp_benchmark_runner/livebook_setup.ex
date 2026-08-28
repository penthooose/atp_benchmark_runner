defmodule AtpBenchmarkRunner.LivebookSetup do
  @moduledoc """
  Livebook setup overlay for the ATP benchmark runner.

  Renders a Kino form to configure every env var the runner reads, so the
  notebook can be run from a container/server with no local `.env` file and no
  SSH access to the machine running it. Everything is configured in the browser.

  ## Behaviour

  - Field defaults resolve in this order: previously persisted value, then the
    `.env` / `.env.example` value (only fills blank fields), then a sensible
    default (path fields use the Livebook session temp dir). The SSH identity
    field also auto-detects a key in the user's `~/.ssh` when nothing is
    configured.
  - Pressing **Setup** applies the values to the OS env (like
    `AtpBenchmarkRunner.load_env!/1`), writes them to a temp `.env` file for
    `HpcConnect.bootstrap/1`, and prints the resolved paths. Staged uploads are
    marked `(temp)` and removed by `cleanup_livebook_setup/1`.
  - Secret fields (`HUGGINGFACE_HUB_TOKEN`) are never persisted.

  ## Usage (notebook, first cell)

      setup =
        AtpBenchmarkRunner.prepare_livebook_setup(
          env_file: Path.expand("../.env", __DIR__),
          fallback_env_file: Path.expand("../.env.example", __DIR__),
          submit_label: "Setup"
        )

      env_map = setup.env_map
      env_file = setup.env_file

  Pass `mode: :local` to skip the UI (used by tests and non-Livebook runs); the
  form defaults are applied directly.
  """

  alias HpcConnect.EnvFile

  @tmp_base "atp_benchmark_runner"
  @default_persist_name "livebook_setup.json"
  @default_env_name "livebook_env.env"
  @default_submit_label "Setup"

  @type spec :: %{
          optional(atom()) => term(),
          key: atom(),
          env: binary(),
          label: binary(),
          type: :text | :select | :secret,
          options: [binary()],
          default: binary(),
          path?: boolean(),
          path_name: binary()
        }

  @doc false
  @spec inputs() :: [spec()]
  def inputs do
    [
      # Paths (default to the Livebook session temp dir)
      path("TPTP_ROOT", :tptp_root, "Paths · TPTP root", "tptp",
        help: "Local TPTP problem library root"
      ),
      path(
        "ATP_BENCHMARK_RUNNER_STORE_DIR",
        :store_dir,
        "Paths · Store dir",
        "store",
        help: "Run manifests / results / reports"
      ),
      path("ATP_BENCHMARK_RUNNER_SMT_TMP_DIR", :smt_tmp, "Paths · SMT temp dir", "smt_converted"),
      path("ATP_BENCHMARK_RUNNER_SMT_THF_DIR", :thf_tmp, "Paths · THF temp dir", "thf_converted"),
      path(
        "ATP_BENCHMARK_RUNNER_SIF_DIR",
        :sif_dir,
        "Paths · Apptainer SIF dir",
        "singularity_images"
      ),
      path(
        "ATP_BENCHMARK_RUNNER_BUNDLED_EXAMPLES_DIR",
        :bundled,
        "Paths · Bundled examples",
        "tptp_examples"
      ),
      path(
        "ATP_BENCHMARK_RUNNER_USER_EXAMPLES_DIR",
        :user_examples,
        "Paths · User examples",
        "user_examples"
      ),
      path(
        "ATP_BENCHMARK_RUNNER_SINGLE_DOWNLOAD_DIR",
        :single_download,
        "Paths · Single download base",
        "downloads"
      ),
      # HPC connection
      select(
        "HPC_CONNECT_CLUSTER",
        :cluster,
        "HPC · Cluster",
        ["helma", "fritz", "alex", "woody", "spr", "tringpu"],
        "helma"
      ),
      text("HPC_CONNECT_USERNAME", :username, "HPC · Username", ""),
      text("HPC_CONNECT_IDENTITY_FILE", :identity_file, "HPC · SSH identity file", ""),
      text("HPC_CONNECT_PROXY_JUMP", :proxy_jump, "HPC · ProxyJump gateway", "csnhr.nhr.fau.de"),
      text(
        "HPC_CONNECT_WORK_DIR",
        :work_dir,
        "HPC · Remote work dir",
        "$HOME/.cache/hpc_connect"
      ),
      text(
        "HPC_CONNECT_VAULT_DIR",
        :vault_dir,
        "HPC · Remote vault dir",
        "$HPCVAULT/.cache/hpc_connect"
      ),
      text("HPC_CONNECT_PORT_RANGE", :port_range, "HPC · Port range (optional)", ""),
      select(
        "HPC_CONNECT_STEADY_CONNECTION",
        :steady,
        "HPC · Steady SSH connection",
        ["true", "false"],
        "true"
      ),
      text(
        "HPC_CONNECT_STEADY_TIMEOUT_SECONDS",
        :steady_timeout,
        "HPC · Steady SSH timeout (s)",
        "30"
      ),
      select(
        "HPC_CONNECT_RETRY_FOREVER",
        :retry_forever,
        "HPC · Retry SSH errors forever",
        ["true", "false"],
        "true"
      ),
      # HPC benchmark defaults
      select(
        "ATP_BENCHMARK_RUNNER_HPC_MODE",
        :hpc_mode,
        "Benchmark · HPC mode",
        ["single_node", "multi_node"],
        "single_node"
      ),
      select(
        "ATP_BENCHMARK_RUNNER_HPC_SINGLE_NODE_MODE",
        :single_node_mode,
        "Benchmark · Single-node mode",
        ["sequential", "parallel"],
        "sequential"
      ),
      select(
        "ATP_BENCHMARK_RUNNER_HPC_SINGLE_NODE_STRATEGY",
        :single_node_strategy,
        "Benchmark · Single-node strategy",
        ["direct_provers", "parallel_sifs", "bundled_container"],
        "direct_provers"
      ),
      text(
        "ATP_BENCHMARK_RUNNER_HPC_PARTITION",
        :partition,
        "Benchmark · SLURM partition",
        "cpu"
      ),
      select(
        "ATP_BENCHMARK_RUNNER_HPC_NODE_KIND",
        :node_kind,
        "Benchmark · Node kind",
        ["cpu", "gpu"],
        "cpu"
      ),
      text("ATP_BENCHMARK_RUNNER_HPC_WALLTIME", :walltime, "Benchmark · Walltime", "02:00:00"),
      text(
        "ATP_BENCHMARK_RUNNER_HPC_MAX_PARALLEL_JOBS",
        :max_parallel,
        "Benchmark · Max parallel jobs",
        "4"
      ),
      select(
        "ATP_BENCHMARK_RUNNER_HPC_NODE_SIZE",
        :node_size,
        "Benchmark · Node size",
        ["full", "half"],
        "full"
      ),
      text(
        "ATP_BENCHMARK_RUNNER_HPC_CPUS_PER_TASK",
        :cpus_per_task,
        "Benchmark · CPUs per task (optional)",
        ""
      ),
      text("ATP_BENCHMARK_RUNNER_HPC_NTASKS", :ntasks, "Benchmark · NTasks", "1"),
      select(
        "ATP_BENCHMARK_RUNNER_HPC_PREPARE_IMAGES",
        :prepare_images,
        "Benchmark · Prepare images",
        ["false", "true"],
        "false"
      ),
      # Secrets (never persisted)
      secret("HUGGINGFACE_HUB_TOKEN", :hf_token, "HuggingFace token (optional)")
    ]
  end

  @doc """
  Renders the setup form (or applies defaults directly in `:local` mode),
  waits for the user to press the submit button, then applies the env values,
  writes them to a temp `.env` file for `HpcConnect.bootstrap/1`, prints the
  resolved paths, and returns:

    * `:env_map` - non-blank env vars that were applied
    * `:env_file` - path to the temp `.env` file (pass to `bootstrap/1`)
    * `:values` - all form values (including blanks)
    * `:persisted_path` - where values are persisted between notebook opens
    * `:ssh_key_path` - the effective SSH identity file (a staged temp key when
      uploaded, otherwise the configured `~/.ssh` path)
    * `:ssh_key_temporary?` - whether `:ssh_key_path` is a temporary upload that
      `cleanup/1` will delete
  """
  @spec prepare(keyword()) :: map()
  def prepare(opts \\ []) do
    mode = Keyword.get(opts, :mode, :livebook)
    if mode == :livebook, do: ensure_kino_available!()

    persist_path = persist_path(opts)
    env_file = resolve_env_file(opts)
    env_map = read_env_map(env_file)
    persisted = load_persisted(persist_path)

    defaults =
      inputs()
      |> resolve_defaults(persisted, env_map, session_tmp_base(opts))
      |> maybe_default_identity()

    case mode do
      :local ->
        finalize(opts, defaults, persist_path)

      _ ->
        prepare_livebook(opts, defaults, persist_path)
    end
  end

  # Renders the form and a status frame, then blocks until the first submit. A
  # persistent owner (`HpcConnect.Livebook.Form`) keeps the subscription alive
  # after the cell finishes, so values can be edited and re-submitted without
  # re-running the cell. Each submit re-applies the env, re-writes the temp
  # `.env`, and re-renders the configured paths into the status frame.
  defp prepare_livebook(opts, defaults, persist_path) do
    # The upload field is always shown so a previously-configured key can be
    # replaced by an upload later; a configured path that exists is still used
    # when no upload is provided.
    configured_key =
      HpcConnect.Livebook.SshKey.configured_path(
        identity_file: Map.get(defaults, "HPC_CONNECT_IDENTITY_FILE")
      )

    form = build_form(defaults, opts)
    frame = kino_frame_new(placeholder: false)

    key_notice =
      if configured_key do
        "Using the configured SSH key ``#{configured_key}``. Upload a different " <>
          "key below to override it for this session."
      else
        "Upload an SSH key below (or set `HPC_CONNECT_IDENTITY_FILE` to an " <>
          "existing key). Uploaded keys are stored **temporarily** and removed " <>
          "by `AtpBenchmarkRunner.cleanup_livebook_setup/1`; your persistent " <>
          "`~/.ssh` key is never touched."
      end

    kino_render(
      kino_markdown("""
      ## ATP benchmark setup

      Values are pre-filled from `.env` / `.env.example` and the last session
      (persisted automatically; files only fill blank fields). Path fields
      default to the session temp dir. Press **#{submit_label(opts)}** to apply;
      you can edit and re-submit.

      #{key_notice}
      """)
    )

    kino_render(form)
    kino_render(frame)

    owner = HpcConnect.Livebook.Form.ensure(:atp_livebook_setup)

    handler = fn data, _event ->
      handle_submit(data, opts, persist_path)
    end

    :ok = HpcConnect.Livebook.Form.attach(owner, form, frame, handler)
    HpcConnect.Livebook.Form.await(owner)
  end

  # Applies one submit after validation: persists, applies env, writes the temp
  # `.env`, renders the configured paths into the status frame, and returns the
  # result map. On invalid input returns `{:retry, frame}` so the owner keeps
  # the cell waiting until everything is valid.
  defp handle_submit(data, opts, persist_path) do
    values =
      Map.new(inputs(), fn spec -> {spec.env, Map.get(data, spec.key)} end)
      |> put_ssh_key(Map.get(data, :identity_file), Map.get(data, :ssh_key_upload))

    case validate_setup(values) do
      :ok ->
        persist_values(persist_path, values)
        apply_env(values)
        env_file = write_env_file(values, opts)
        env_map = non_blank(values)
        ssh_key = ssh_key_info(values)

        result = %{
          env_map: env_map,
          env_file: env_file,
          values: values,
          persisted_path: persist_path,
          ssh_key_path: ssh_key.path,
          ssh_key_temporary?: ssh_key.temporary?
        }

        frame =
          kino_markdown(
            "```\n" <>
              configured_paths_text(env_file, Map.get(values, "HPC_CONNECT_IDENTITY_FILE")) <>
              "\n```"
          )

        {result, frame}

      {:error, message} ->
        {:retry, kino_markdown("**Setup not applied:** #{message}")}
    end
  end

  # Validates what the following cells need before §1 returns: an HPC username
  # and an SSH identity file that exists on disk.
  defp validate_setup(values) do
    cond do
      not non_blank?(values["HPC_CONNECT_USERNAME"]) ->
        {:error, "HPC username is missing. Enter it and press Setup again."}

      not non_blank?(values["HPC_CONNECT_IDENTITY_FILE"]) ->
        {:error,
         "No SSH identity file. Upload a key or set HPC_CONNECT_IDENTITY_FILE, then press Setup again."}

      not File.exists?(Path.expand(values["HPC_CONNECT_IDENTITY_FILE"])) ->
        {:error,
         "The SSH identity file #{values["HPC_CONNECT_IDENTITY_FILE"]} does not exist. " <>
           "Upload a key or fix the path, then press Setup again."}

      true ->
        :ok
    end
  end

  # Resolves the effective SSH identity file: an uploaded key wins, otherwise a
  # configured path that exists is used, otherwise the typed value is kept.
  defp put_ssh_key(values, typed_path, upload) do
    identity =
      case HpcConnect.Livebook.SshKey.resolve([identity_file: typed_path], upload) do
        {:configured, path} -> path
        {:uploaded, path} -> HpcConnect.Livebook.SshKey.stage_upload(path)
        :missing -> typed_path || ""
      end

    Map.put(values, "HPC_CONNECT_IDENTITY_FILE", identity)
  end

  @doc false
  # Resolves each field's default: persisted > env file > tmp/default.
  @spec resolve_defaults([spec()], map(), map(), binary()) :: %{binary() => binary() | nil}
  def resolve_defaults(inputs, persisted, env_map, tmp_base) do
    Map.new(inputs, fn spec ->
      {spec.env, resolve_value(spec, persisted, env_map, tmp_base)}
    end)
  end

  # Auto-detects a private key in the user's `~/.ssh` (cross-platform) when no
  # persisted or env identity is configured, so the field pre-fills with a real
  # key instead of a hardcoded name.
  defp maybe_default_identity(defaults) do
    case Map.get(defaults, "HPC_CONNECT_IDENTITY_FILE") do
      value when is_binary(value) and value != "" ->
        defaults

      _ ->
        case HpcConnect.Livebook.SshKey.default_identity_path() do
          nil -> defaults
          path -> Map.put(defaults, "HPC_CONNECT_IDENTITY_FILE", path)
        end
    end
  end

  @doc false
  defp resolve_value(spec, persisted, env_map, tmp_base) do
    cond do
      non_blank?(Map.get(persisted, spec.env)) -> Map.get(persisted, spec.env)
      non_blank?(Map.get(env_map, spec.env)) -> Map.get(env_map, spec.env)
      spec[:path?] -> Path.join(tmp_base, spec.path_name || spec.env)
      true -> spec[:default] || ""
    end
  end

  @doc false
  # Filters a value map down to non-blank entries.
  @spec non_blank(map()) :: map()
  def non_blank(values) when is_map(values) do
    values |> Enum.reject(fn {_k, v} -> not non_blank?(v) end) |> Map.new()
  end

  @doc false
  def non_blank?(nil), do: false
  def non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  def non_blank?(_value), do: false

  @doc false
  # Serializes a value map as `KEY=VALUE` lines for a `.env` file.
  @spec render_env_content(map()) :: binary()
  def render_env_content(values) when is_map(values) do
    values
    |> non_blank()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> format_env_line(key, value) end)
  end

  @doc false
  defp format_env_line(key, value) do
    if value =~ ~r/[\s#"]/ do
      escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "#{key}=\"#{escaped}\""
    else
      "#{key}=#{value}"
    end
  end

  @doc false
  # Writes the non-blank values to a temp `.env` file and returns its path
  # (via `Path.expand`, so it uses the platform's canonical separator on both
  # Windows and Linux).
  @spec write_env_file(map(), keyword()) :: binary()
  def write_env_file(values, opts) do
    path =
      Keyword.get(
        opts,
        :env_output_path,
        Path.join([System.tmp_dir!(), @tmp_base, @default_env_name])
      )

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render_env_content(values) <> "\n")
    Path.expand(path)
  end

  defp finalize(opts, values, persist_path) do
    persist_values(persist_path, values)
    apply_env(values)
    env_file = write_env_file(values, opts)
    IO.puts(configured_paths_text(env_file, Map.get(values, "HPC_CONNECT_IDENTITY_FILE")))
    env_map = non_blank(values)
    ssh_key = ssh_key_info(values)

    %{
      env_map: env_map,
      env_file: env_file,
      values: values,
      persisted_path: persist_path,
      ssh_key_path: ssh_key.path,
      ssh_key_temporary?: ssh_key.temporary?
    }
  end

  defp apply_env(values) do
    Enum.each(values, fn {key, value} ->
      if non_blank?(value), do: System.put_env(key, value)
    end)
  end

  # Single source for the configured-paths report: printed in `:local` mode and
  # rendered into the Livebook status frame (fenced) in `:livebook` mode. The
  # SSH identity line is marked `(temp)` when the key is a staged upload that
  # cleanup will remove.
  defp configured_paths_text(env_file, ssh_key) do
    "Configured paths:\n" <>
      "  TPTP_ROOT:      #{AtpBenchmarkRunner.tptp_dir()}\n" <>
      "  Store dir:      #{AtpBenchmarkRunner.store_dir()}\n" <>
      "  SMT temp dir:   #{AtpBenchmarkRunner.Config.smt_tmp_dir()}\n" <>
      ssh_key_line(ssh_key) <>
      "  .env file:      #{env_file}"
  end

  defp ssh_key_line(ssh_key) do
    cond do
      non_blank?(ssh_key) and HpcConnect.Livebook.SshKey.temp_path?(ssh_key) ->
        "  SSH key (temp): #{ssh_key}\n"

      non_blank?(ssh_key) ->
        "  SSH key:        #{ssh_key}\n"

      true ->
        ""
    end
  end

  defp ssh_key_info(values) do
    case Map.get(values, "HPC_CONNECT_IDENTITY_FILE") do
      path when is_binary(path) and path != "" ->
        %{path: path, temporary?: HpcConnect.Livebook.SshKey.temp_path?(path)}

      _ ->
        %{path: nil, temporary?: false}
    end
  end

  # field helpers

  defp text(env, key, label, default),
    do: %{key: key, env: env, label: label, type: :text, default: default}

  defp select(env, key, label, options, default),
    do: %{key: key, env: env, label: label, type: :select, options: options, default: default}

  defp secret(env, key, label),
    do: %{key: key, env: env, label: label, type: :secret, default: ""}

  defp path(env, key, label, path_name, opts \\ []) do
    base = %{key: key, env: env, label: label, type: :text, path?: true, path_name: path_name}
    extras = opts |> Keyword.take([:help, :default]) |> Map.new()
    Map.merge(base, extras)
  end

  defp build_form(defaults, opts) do
    env_fields =
      Enum.map(inputs(), fn spec ->
        {spec.key, input_for(spec, Map.get(defaults, spec.env))}
      end)

    upload_fields = [
      ssh_key_upload: kino_input_file("Upload SSH private key (optional)", accept: :any)
    ]

    kino_control_form(env_fields ++ upload_fields, submit: submit_label(opts))
  end

  @doc false
  # Kino >= 0.19 requires select options as `{value, label}` tuples, not a flat
  # string list, so the spec's string options are converted at render time.
  @spec select_options([binary()]) :: [{binary(), binary()}]
  def select_options(options) when is_list(options), do: Enum.map(options, &{&1, &1})

  defp input_for(%{type: :select} = spec, default) do
    kino_input_select(spec.label, select_options(spec.options), default: default)
  end

  defp input_for(%{type: :secret} = spec, default) do
    kino_input_password(spec.label, default: default || "")
  end

  defp input_for(spec, default) do
    kino_input_text(spec.label, default: default || "")
  end

  @doc """
  Deletes any temporary SSH key uploaded by the setup overlay (never a
  persistent `~/.ssh` key) and prints a short notice. No error when nothing
  is left to delete.
  """
  @spec cleanup(keyword()) :: :ok
  def cleanup(opts \\ []) do
    HpcConnect.Livebook.SshKey.cleanup_notice(opts)
  end

  @doc false
  defp submit_label(opts), do: Keyword.get(opts, :submit_label, @default_submit_label)

  # persistence / env resolution

  defp session_tmp_base(opts) do
    Keyword.get(opts, :tmp_base, Path.join(System.tmp_dir!(), @tmp_base))
  end

  defp persist_path(opts) do
    Keyword.get(
      opts,
      :persist_path,
      Path.join([System.tmp_dir!(), @tmp_base, @default_persist_name])
    )
  end

  defp resolve_env_file(opts) do
    preferred = Keyword.get(opts, :env_file)
    fallback = Keyword.get(opts, :fallback_env_file)

    cond do
      is_binary(preferred) and File.exists?(preferred) -> preferred
      is_binary(fallback) and File.exists?(fallback) -> fallback
      is_binary(preferred) -> preferred
      is_binary(fallback) -> fallback
      true -> nil
    end
  end

  defp read_env_map(nil), do: %{}
  defp read_env_map(path), do: EnvFile.load(path)

  defp load_persisted(persist_path) do
    with {:ok, json} <- File.read(persist_path),
         {:ok, data} <- Jason.decode(json),
         true <- is_map(data) do
      data
    else
      _ -> %{}
    end
  end

  defp persist_values(persist_path, values) do
    persistable =
      values
      |> non_blank()
      |> Enum.reject(fn {key, _value} ->
        spec = Enum.find(inputs(), &(&1.env == key))
        spec && spec.type == :secret
      end)
      |> Map.new()

    File.mkdir_p!(Path.dirname(persist_path))
    _ = File.write(persist_path, Jason.encode!(persistable, pretty: true))
    :ok
  end

  # Kino indirection (no hard compile-time Kino dependency)

  defp ensure_kino_available! do
    unless Code.ensure_loaded?(kino_module()) and Code.ensure_loaded?(kino_input_module()) and
             Code.ensure_loaded?(kino_control_module()) and
             Code.ensure_loaded?(kino_frame_module()) and
             Code.ensure_loaded?(kino_markdown_module()) do
      raise ArgumentError,
            "Kino is required for the Livebook setup form. Add {:kino, \"~> 0.13\"} to Mix.install/1."
    end
  end

  defp kino_render(term), do: apply(kino_module(), :render, [term])
  defp kino_markdown(text), do: apply(kino_markdown_module(), :new, [text])
  defp kino_frame_new(opts), do: apply(kino_frame_module(), :new, [opts])

  defp kino_input_text(label, opts), do: apply(kino_input_module(), :text, [label, opts])

  defp kino_input_password(label, opts),
    do: apply(kino_input_module(), :password, [label, opts])

  defp kino_input_select(label, options, opts),
    do: apply(kino_input_module(), :select, [label, options, opts])

  defp kino_input_file(label, opts), do: apply(kino_input_module(), :file, [label, opts])

  defp kino_control_form(fields, opts), do: apply(kino_control_module(), :form, [fields, opts])

  defp kino_module, do: Kino
  defp kino_input_module, do: Module.concat([Kino, Input])
  defp kino_control_module, do: Module.concat([Kino, Control])
  defp kino_frame_module, do: Module.concat([Kino, Frame])
  defp kino_markdown_module, do: Module.concat([Kino, Markdown])
end
