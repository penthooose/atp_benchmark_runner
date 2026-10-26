defmodule AtpBenchmarkRunner.Input do
  @moduledoc """
  Decides what a prover is fed for one (prover, problem) pair.

  The decision needs both sides, so it cannot come from the prover spec alone:
  includes are inlined first, then the problem's dialect is worked out. A prover
  that accepts that dialect gets the file untouched; otherwise the conversion it
  declares runs, and only if that conversion keeps every statement. Anything left
  is a skip with a reason, which the runner reports as `InputError`.

  `plan/3` does the same for a whole run and is what the HPC path uses, so local
  and cluster runs prepare input identically.
  """

  alias AtpBenchmarkRunner.{Config, Problem, Prover, Result, TPTPToSMT}
  alias AtpBenchmarkRunner.TPTP.{Dialect, Includes, ToTHF}

  @type kind :: :native | :expanded | :smt2 | :thf

  @typedoc "Prepared input: the path to hand the prover plus where it came from."
  @type prepared :: %{path: binary(), kind: kind(), dialect: Dialect.t()}

  @typedoc "A pair that cannot be run, with the reason."
  @type skip :: %{
          prover: atom(),
          problem_id: binary(),
          problem_name: binary(),
          status: binary(),
          reason: binary(),
          detail: term()
        }

  @doc """
  Prepares the input for one prover and one problem.

  Options: `:output_dir` (`:config` stages in the configured temp dirs,
  `:adjacent` writes beside the problem) and `:tptp_root` (where includes
  resolve).
  """
  @spec prepare(Prover.t() | atom() | binary(), Problem.t() | binary(), keyword()) ::
          {:ok, prepared()} | {:skip, map()}
  def prepare(prover, problem, opts \\ []) do
    prover = Prover.normalize(prover)
    problem = normalize_problem(problem)

    case expand_and_detect(problem, opts) do
      {:ok, input} -> choose(prover, input, problem, opts)
      {:skip, skip} -> {:skip, skip}
    end
  end

  @doc """
  Prepares a whole run in one pass, expanding each problem's includes once instead
  of once per prover.

  Returns `%{entries: [...], skips: [...], inputs: %{"prover|problem_id" => {:ok,
  prepared} | {:skip, skip}}}`.
  """
  @spec plan([Prover.t() | atom() | binary()], [Problem.t() | binary()], keyword()) :: map()
  def plan(provers, problems, opts \\ []) do
    provers = Enum.map(provers, &Prover.normalize/1)
    problems = Enum.map(problems, &normalize_problem/1)

    problems
    |> Enum.reduce(%{entries: [], skips: [], inputs: %{}}, fn problem, acc ->
      case expand_and_detect(problem, opts) do
        {:ok, input} -> Enum.reduce(provers, acc, &add_entry(&1, &2, input, problem, opts))
        {:skip, skip} -> add_skips(acc, provers, problem, skip)
      end
    end)
    |> Map.update!(:entries, &Enum.reverse/1)
    |> Map.update!(:skips, &Enum.reverse/1)
  end

  @doc """
  The skips of a plan as `InputError` results.

  An unusable problem is an input problem, not a prover failure, so `Report` and
  `MultiRun` already treat the status as a non-attempt.
  """
  @spec skipped_results(map() | [skip()]) :: [Result.t()]
  def skipped_results(%{skips: skips}), do: skipped_results(skips)
  def skipped_results(skips) when is_list(skips), do: Enum.map(skips, &skipped_result/1)

  @doc "One skip as an `InputError` result."
  @spec skipped_result(skip()) :: Result.t()
  def skipped_result(%{} = skip) do
    Result.new(%{
      problem_id: skip.problem_id,
      problem_name: skip.problem_name,
      prover: skip.prover,
      szs_status: skip.status,
      wall_time_ms: 0,
      metadata: %{reason: skip.reason, input_skip: skip.detail}
    })
  end

  @doc "Reads a run-metadata key, also when it is a string."
  @spec metadata(map(), atom(), term()) :: term()
  def metadata(metadata, key, default \\ nil) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key)) || default
  end

  @doc "Mount directory and file name for a prepared input."
  @spec mount_for(binary()) :: {binary(), binary()}
  def mount_for(path) do
    {path |> Path.dirname() |> Path.expand(), Path.basename(path)}
  end

  @doc """
  Input path a task script runs for a prover, derived from the prover spec.

  Used for manifests written before prepared paths existed; new runs carry the
  resolved path in `run.metadata.prepared_inputs`.
  """
  @spec remote_input_path(Prover.t(), binary() | Problem.t()) :: binary()
  def remote_input_path(%Prover{} = prover, problem_or_path) do
    path = problem_path(problem_or_path)

    case prover.input do
      :tptp -> path
      :smt2 -> replace_ext(path, ".smt2")
      :thf -> replace_ext(path, "_thf.p")
      {:to_thf, _flavour} -> replace_ext(path, "_thf.p")
      {:custom, mod} when is_atom(mod) -> mod.remote_input_path(path)
      other -> raise ArgumentError, "unknown input mode for #{prover.name}: #{inspect(other)}"
    end
  end

  @doc "Name of an input kind, for result metadata."
  @spec kind_label(kind()) :: binary()
  def kind_label(:native), do: "native"
  def kind_label(:expanded), do: "expanded includes"
  def kind_label(:smt2), do: "SMT-LIB"
  def kind_label(:thf), do: "THF"

  # Decision layer

  defp expand_and_detect(problem, opts) do
    path = problem_path(problem)

    with {:ok, expanded} <- expand(path, opts),
         {:ok, dialect} <- detect(expanded.path, opts) do
      {:ok,
       %{
         path: expanded.path,
         kind: if(expanded.expanded?, do: :expanded, else: :native),
         dialect: dialect
       }}
    else
      {:error, reason} -> {:skip, skip_from_error(reason)}
    end
  end

  defp expand(path, opts) do
    Includes.expand(path,
      output_dir: staging_dir(opts, :expanded, path),
      tptp_root: tptp_root(opts)
    )
  end

  defp detect(path, opts) do
    Dialect.detect(path, Keyword.take(opts, [:path]))
  end

  defp choose(%Prover{} = prover, %{dialect: dialect} = input, problem, opts) do
    cond do
      Dialect.accepts?(prover.accepts, dialect) -> {:ok, input}
      Dialect.accepts?(prover.converts, dialect) -> convert(prover, input, problem, opts)
      true -> {:skip, unsupported_dialect(prover, dialect)}
    end
  end

  # A conversion only runs for a dialect it actually covers: pushing a THF
  # problem through a first-order encoding would answer a different question.
  defp unsupported_dialect(%Prover{} = prover, %{label: label}) do
    skip_map(
      "#{prover.label} does not support #{label} input " <>
        "(accepts: #{describe_dialects(prover.accepts)}; converts: #{describe_dialects(prover.converts)})",
      {:unsupported_dialect, label}
    )
  end

  defp describe_dialects(:all), do: "all"
  defp describe_dialects([]), do: "none"
  defp describe_dialects(forms), do: forms |> Enum.map_join(", ", &Dialect.form_name/1)

  defp convert(%Prover{input: :tptp} = prover, %{dialect: dialect}, _problem, _opts) do
    {:skip,
     skip_map(
       "#{prover.label} does not accept #{dialect.label} input",
       {:unsupported_dialect, dialect.label}
     )}
  end

  defp convert(%Prover{input: :smt2} = prover, input, problem, opts),
    do: to_smt2(prover, input, problem, opts)

  defp convert(%Prover{input: :thf} = prover, input, problem, opts),
    do: to_thf(prover, input, problem, opts, :lash)

  defp convert(%Prover{input: {:to_thf, flavour}} = prover, input, problem, opts),
    do: to_thf(prover, input, problem, opts, flavour)

  defp convert(%Prover{input: {:custom, mod}} = prover, input, problem, opts) do
    custom_input(prover, mod, input, problem, opts)
  end

  defp convert(%Prover{} = prover, input, _problem, _opts) do
    {:skip,
     skip_map(
       "#{prover.label} cannot consume #{input.dialect.label} input",
       {:unsupported_dialect, input.dialect.label}
     )}
  end

  defp custom_input(prover, mod, input, problem, _opts) do
    with :ok <- run_custom(fn -> mod.convert(input.path) end) do
      {:ok, %{input | path: custom_path(mod, input, problem)}}
    else
      {:error, message} -> {:skip, conversion_skip(prover, {:conversion_failed, message})}
    end
  end

  defp run_custom(fun) do
    fun.()
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp to_smt2(prover, input, _problem, opts) do
    dir = staging_dir(opts, :smt2, input.path)
    target = Path.join(dir, staged_name(input.path, ".smt2"))

    with {:ok, source} <- read(input.path),
         {:ok, converted} <-
           checked_conversion(source, fn -> TPTPToSMT.convert_string!(source) end) do
      _ = write(target, converted)
      {:ok, %{input | path: target, kind: :smt2}}
    else
      {:error, reason} -> {:skip, conversion_skip(prover, reason)}
    end
  end

  defp to_thf(prover, input, _problem, opts, flavour) do
    dir = staging_dir(opts, :thf, input.path)
    target = Path.join(dir, staged_name(input.path, "_thf.p"))

    with {:ok, source} <- read(input.path),
         {:ok, converted} <-
           checked_conversion(source, fn -> to_thf_string(source, flavour) end),
         :ok <- validate_thf(converted) do
      _ = write(target, converted)
      {:ok, %{input | path: target, kind: :thf}}
    else
      {:error, reason} -> {:skip, conversion_skip(prover, reason)}
    end
  end

  # The flavour names which converter runs; a typo in a prover spec fails here
  # instead of silently producing Lash output for another prover.
  defp to_thf_string(source, :lash), do: ToTHF.convert_string(source)

  defp to_thf_string(_source, flavour),
    do: raise(ArgumentError, "unknown THF conversion flavour #{inspect(flavour)}")

  # A conversion is only accepted when it accounted for every statement of the
  # source. The converters drop what they cannot parse, so without this gate a
  # problem could reach a prover missing axioms and still record a verdict.
  defp checked_conversion(source, convert_fun) do
    %{declared: declared, parsed: parsed} = TPTPToSMT.conversion_counts(source)

    cond do
      parsed != declared -> {:error, {:conversion_incomplete, declared, parsed}}
      true -> {:ok, convert_fun.()}
    end
  rescue
    e -> {:error, {:conversion_failed, Exception.message(e)}}
  end

  # A converted THF file must still be valid TPTP, otherwise the converter
  # emitted something no prover will read.
  defp validate_thf(converted) do
    case Dialect.detect_string(converted) do
      {:ok, _dialect} -> :ok
      {:error, reason} -> {:error, {:conversion_invalid, reason}}
    end
  end

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp conversion_skip(prover, reason) do
    skip_map("#{prover.label} input conversion failed: #{describe(reason)}", reason)
  end

  defp describe({:conversion_incomplete, declared, parsed}) do
    "the converter kept #{parsed} of #{declared} statements, so the problem would " <>
      "reach the prover incomplete"
  end

  defp describe({:conversion_invalid, _reason}), do: "the converted problem is not valid TPTP"
  defp describe({:conversion_failed, message}), do: message
  defp describe({:unreadable, reason}), do: "cannot read the problem: #{inspect(reason)}"

  defp describe({:invalid, messages}),
    do: "not valid TPTP: #{Enum.join(List.wrap(messages), "; ")}"

  defp describe({:invalid_problem, messages}),
    do: "not valid TPTP: #{Enum.join(List.wrap(messages), "; ")}"

  defp describe(other), do: inspect(other)

  defp skip_from_error({:include_unresolved, messages}) do
    skip_map("include directives could not be resolved: #{Enum.join(messages, "; ")}", {
      :include_unresolved,
      messages
    })
  end

  defp skip_from_error({:invalid, messages}) do
    skip_map("the problem is not valid TPTP: #{Enum.join(messages, "; ")}", {
      :invalid_problem,
      messages
    })
  end

  defp skip_from_error({:invalid_problem, messages}) do
    skip_map("the problem is not valid TPTP: #{Enum.join(messages, "; ")}", {
      :invalid_problem,
      messages
    })
  end

  defp skip_from_error({:unparsable, messages}) do
    skip_map("the problem could not be parsed: #{Enum.join(messages, "; ")}", {
      :unparsable,
      messages
    })
  end

  defp skip_from_error({:unreadable, messages}) do
    skip_map("the problem could not be read: #{Enum.join(List.wrap(messages), "; ")}", {
      :unreadable,
      messages
    })
  end

  defp skip_map(reason, detail) do
    %{status: "InputError", reason: reason, detail: detail}
  end

  defp add_entry(%Prover{} = prover, acc, input, problem, opts) do
    case choose(prover, input, problem, opts) do
      {:ok, prepared} ->
        entry = %{
          prover: prover,
          problem: problem,
          path: prepared.path,
          kind: prepared.kind,
          dialect: prepared.dialect
        }

        %{
          acc
          | entries: [entry | acc.entries],
            inputs: Map.put(acc.inputs, key(prover, problem), {:ok, prepared})
        }

      {:skip, skip} ->
        add_skips(acc, [prover], problem, skip)
    end
  end

  defp add_skips(acc, provers, problem, skip) do
    new_skips =
      Enum.map(provers, fn prover ->
        %{
          prover: prover.name,
          problem_id: problem.id,
          problem_name: problem.name,
          status: skip.status,
          reason: "#{prover.label}: #{skip.reason}",
          detail: skip.detail
        }
      end)

    inputs =
      Enum.reduce(provers, acc.inputs, fn prover, acc_inputs ->
        Map.put(acc_inputs, key(prover, problem), {:skip, skip})
      end)

    %{acc | skips: new_skips ++ acc.skips, inputs: inputs}
  end

  defp key(%Prover{name: name}, %Problem{id: id}), do: "#{name}|#{id}"

  # Paths

  # `:adjacent` keeps the generated file beside the problem so the HPC sync
  # uploads it with the existing batched transfer; `:config` stages it in the
  # configured temp dir for local runs.
  defp staging_dir(opts, kind, source) do
    case Keyword.get(opts, :output_dir, :config) do
      :adjacent ->
        Path.dirname(source)

      dir when is_binary(dir) ->
        dir

      _ ->
        case kind do
          :expanded -> Config.expanded_tmp_dir(opts)
          :smt2 -> Config.smt_tmp_dir(opts)
          :thf -> Config.thf_tmp_dir(opts)
        end
    end
  end

  # Includes are written as `Axioms/GRP003-0.ax` and resolve against the library
  # roots, which for an unpacked archive is the versioned subdirectory.
  defp tptp_root(opts) do
    opts
    |> Keyword.get_lazy(:tptp_root, fn -> Config.tptp_dir(opts) end)
    |> Includes.roots()
  end

  # Staged conversions share one directory, so the name carries a short hash of
  # the source path: two same-named problems from different directories must not
  # overwrite each other's conversion.
  defp staged_name(path, suffix) do
    base = Path.basename(path) |> strip_extension()
    hash = path |> Path.expand() |> then(&:erlang.phash2/1) |> Integer.to_string(16)
    "#{base}_#{hash}#{suffix}"
  end

  defp strip_extension(name) do
    name
    |> String.replace_suffix(".p", "")
    |> String.replace_suffix(".tptp", "")
  end

  defp replace_basename_ext(path, suffix) do
    name = Path.basename(path)

    cond do
      String.ends_with?(name, ".p") -> String.replace_suffix(name, ".p", suffix)
      String.ends_with?(name, ".tptp") -> String.replace_suffix(name, ".tptp", suffix)
      true -> name
    end
  end

  defp replace_ext(path, suffix) do
    Path.join(Path.dirname(path), replace_basename_ext(path, suffix))
  end

  defp custom_path(mod, input, problem) do
    mod.remote_input_path(problem_path(problem)) || input.path
  end

  defp problem_path(%Problem{path: path}) when is_binary(path), do: path
  defp problem_path(%Problem{name: name}), do: name
  defp problem_path(path) when is_binary(path), do: path

  defp normalize_problem(%Problem{} = problem), do: problem
  defp normalize_problem(path) when is_binary(path), do: Problem.from_path(path)
end
