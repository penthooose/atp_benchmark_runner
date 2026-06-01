defmodule AtpBenchmarkRunner.Provers.Provider do
  @moduledoc """
  Behaviour implemented by prover provider modules.
  """

  alias AtpBenchmarkRunner.Prover
  alias AtpBenchmarkRunner.Prover.Container

  @callback prover() :: Prover.t()
  @callback container() :: Container.t()
  @callback research_notes() :: [binary()]
end
