defmodule Ximula.Sim.StageExecutor.Grid do
  alias Ximula.Grid

  def get_data(%{data: grid}) do
    Grid.map(grid, fn x, y, field ->
      %{position: {x, y}, field: field}
    end)
  end

  def reduce_data({:error, reasons}, _input), do: {:error, reasons}

  def reduce_data({:ok, results}, %{data: grid}) do
    results = Enum.map(results, fn %{position: position, field: field} -> {position, field} end)
    {:ok, Grid.apply_changes(grid, results)}
  end
end
