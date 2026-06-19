defmodule AtpBenchmarkRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :atp_benchmark_runner,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Local path while item #15 is developed. Later replace with the public repo, e.g.:
      # {:hpc_connect, github: "<aise-org-or-user>/hpc_connect", tag: "v0.1.0"}
      # {:hpc_connect, path: "../../item_15_Elixir_HPC_Connect_Library/hpc_connect"},

      {:jason, "~> 1.4"},
      {:kino, "~> 0.13"},
      {:hpc_connect, github: "penthooose/hpc_connect", force: true},
      {:req, "~> 0.5"},
      {:oban, "~> 2.19", optional: true}
    ]
  end
end
