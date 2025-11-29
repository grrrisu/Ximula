defmodule Ximula.Sim.StageAdapter.Grid do
  @moduledoc """
  Executes a stage across all positions in a grid, in parallel.

  Used for spatial simulations where entities are organized in a 2D grid
  and each cell can be processed independently.

  ## Adapter Protocol

  Implements two functions:

  - `get_data/1` - Extracts all grid positions as `%{position: {x, y}, field: data}`
  - `reduce_data/2` - Applies results back to grid via `Grid.apply_changes/2`

  ## Performance

  - Each grid cell processed in parallel via `TaskRunner`
  - No coordination between cells (use `Gatekeeper` if needed)
  - Efficient for large grids (1000+ cells)
  - Telemetry tracks entity count and duration

  ## When to Use

  - Spatial 2D simulations (terrain, vegetation, buildings)
  - Independent entity processing
  - Large-scale parallel workloads

  ## When NOT to Use

  - Entities need to interact (migration, combat) → use `Gatekeeper`
  - Single entity → use `Single`
  - Non-spatial entities → use custom adapter or `Single`
  """

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
