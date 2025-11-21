defmodule Ximula.Sim.StageExecutor.Grid do
  alias Ximula.Grid
  alias Ximula.Sim.{Change, TaskRunner}

  def execute_stage(steps, %{data: grid, opts: opts}) do
    positions = Grid.positions(grid)

    TaskRunner.sim(
      positions,
      {__MODULE__, :execute_steps, [[steps: steps, grid: grid]]},
      opts[:supervisor],
      opts
    )
    |> notify_stage_observesrs(opts)
    |> handle_sim_results()
    |> reduce_grid(grid)
  end

  def execute_steps(position, steps: steps, grid: grid) do
    field = Grid.get(grid, position)

    Enum.reduce(
      steps,
      %Change{data: %{position: position, field: field}},
      fn %{module: module, function: function}, change ->
        change = apply(module, function, [change])
        notify_step_observesrs(change)
        change
      end
    )
    |> Change.reduce()
  end

  defp handle_sim_results(%{ok: ok, exit: failed}) do
    cond do
      Enum.any?(failed) ->
        {:error,
         failed
         |> Enum.map(fn {_data, {exception, stacktrace}} ->
           Exception.normalize(:error, exception, stacktrace) |> Exception.message()
         end)}

      Enum.any?(ok) ->
        {:ok, ok}
    end
  end

  def reduce_grid({:error, reasons}, _grid), do: {:error, reasons}

  def reduce_grid({:ok, results}, grid) do
    results = Enum.map(results, fn %{position: position, field: field} -> {position, field} end)
    {:ok, Grid.apply_changes(grid, results)}
  end

  def notify_stage_observesrs(%{ok: ok, exit: failed} = results, opts) do
    results
  end

  def notify_step_observesrs(%Change{data: data, changes: changes}) do
  end
end
