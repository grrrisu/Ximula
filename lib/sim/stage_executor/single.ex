defmodule Ximula.Sim.StageExecutor.Single do
  @moduledoc """
  Executes a stage on a single entity.

  Used when a stage operates on one aggregated entity rather than
  a collection. For example: world-level calculations, single settlement
  updates, or non-spatial simulations.

  ## Executor Protocol

  Implements two functions:

  - `get_data/1` - Extracts entity from input (identity function)
  - `reduce_data/2` - Returns first result from task execution

  ## When to Use

  - Single aggregated entity (world state, global counters)
  - Non-spatial simulations
  - Sequential processing where parallelism doesn't make sense
  - Stages that coordinate between parallel stages

  ## When NOT to Use

  - Multiple entities that can run in parallel → use `Grid`
  - Cross-entity operations that need locking → use `Gatekeeper`
  """
  def get_data(%{data: data}), do: data

  def reduce_data({:error, reasons}, _input), do: {:error, reasons}

  def reduce_data({:ok, results}, _input) do
    {:ok, List.first(results)}
  end
end
