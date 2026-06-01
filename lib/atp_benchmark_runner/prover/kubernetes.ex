defmodule AtpBenchmarkRunner.Prover.Kubernetes do
  @moduledoc """
  Kubernetes job manifest generation for future cloud/container backends.

  FAU HPC execution should use Apptainer via `AtpBenchmarkRunner.HPC.Images`.
  This module only produces plain maps so callers can encode them as YAML/JSON
  with their deployment tooling of choice.
  """

  alias AtpBenchmarkRunner.{Prover, Provers}

  @doc """
  Builds a Kubernetes Job manifest map for one prover/problem execution.
  """
  @spec job_manifest(Prover.t() | atom() | binary(), binary(), keyword()) :: map()
  def job_manifest(prover_or_name, problem_path, opts \\ []) do
    prover = normalize_prover(prover_or_name)
    container = Provers.container!(prover.name)

    image =
      Keyword.get(opts, :image) || container.docker_image ||
        raise ArgumentError, "missing container image for #{prover.name}"

    name = Keyword.get(opts, :name, "atp-#{prover.name}") |> dns_label()
    timeout = Keyword.get(opts, :timeout_seconds, 300)

    %{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: %{name: name},
      spec: %{
        backoffLimit: Keyword.get(opts, :backoff_limit, 0),
        template: %{
          spec: %{
            restartPolicy: "Never",
            containers: [
              %{
                name: Atom.to_string(prover.name),
                image: image,
                imagePullPolicy: Keyword.get(opts, :image_pull_policy, "IfNotPresent"),
                command: ["/bin/sh", "-lc"],
                args: [container_command(prover, problem_path, timeout)],
                resources: Keyword.get(opts, :resources, default_resources())
              }
            ]
          }
        }
      }
    }
  end

  defp container_command(%Prover{} = prover, problem_path, timeout) do
    command =
      prover.command_template
      |> String.replace("apptainer exec {sif_path} ", "")
      |> String.replace("{problem}", shell_quote(problem_path))
      |> String.replace("{timeout_seconds}", to_string(timeout))
      |> String.replace("{timeout_ms}", to_string(timeout * 1_000))
      |> String.replace("{result_file}", "result.out")

    "timeout --preserve-status #{timeout}s #{command}"
  end

  defp normalize_prover(%Prover{} = prover), do: prover
  defp normalize_prover(name), do: Provers.fetch!(name)

  defp default_resources do
    %{
      requests: %{cpu: "1", memory: "1Gi"},
      limits: %{cpu: "2", memory: "4Gi"}
    }
  end

  defp dns_label(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 63)
  end

  defp shell_quote(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end
