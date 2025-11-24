defmodule Ximula.Sim.StageExecutor.Single do
  alias Ximula.Sim.{Change, TaskRunner}

  def execute_stage(steps, %{data: data, opts: opts}) do
    TaskRunner.sim(
      data,
      {__MODULE__, :execute_steps, [[steps: steps]]},
      opts[:supervisor],
      opts
    )
    |> notify_stage_observesrs(opts)
    |> handle_sim_results()
    |> reduce_data()
  end

  def execute_steps(data, steps: steps) do
    Enum.reduce(
      steps,
      %Change{data: data},
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
      Enum.empty?(ok) ->
        {:error,
         failed
         |> Enum.map(fn {_data, {exception, stacktrace}} ->
           Exception.normalize(:error, exception, stacktrace) |> Exception.message()
         end)
         |> List.first()}

      Enum.any?(ok) ->
        {:ok, ok}
    end
  end

  def reduce_data({:error, reasons}, _grid), do: {:error, reasons}

  def reduce_data({:ok, results}) do
    {:ok, List.first(results)}
  end

  def notify_stage_observesrs(%{ok: ok, exit: failed} = results, opts) do
    results
  end

  def notify_step_observesrs(%Change{data: data, changes: changes}) do
  end
end
