defmodule Ximula.Sim.StageExecutor.Single do
  def get_data(%{data: data}), do: data

  def reduce_data({:error, reasons}, _input), do: {:error, reasons}

  def reduce_data({:ok, results}, _input) do
    {:ok, List.first(results)}
  end
end
