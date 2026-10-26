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
      {:hpc_connect, github: "penthooose/hpc_connect"},
      # TPTP/SZS language library: header parsing, include expansion, and the
      # official SZS ontology. Owns the dialect and status vocabulary the
      # runner must not re-implement (see tasks/tasks_fix_thf.md).
      {:tptp, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:kino, "~> 0.19"},
      {:req, "~> 0.5"},
      {:oban, "~> 2.19", optional: true}
    ]
  end
end
