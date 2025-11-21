defmodule Ximula.Sim.StageExecutor.Gatekeeper do
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper
  alias Ximula.Sim.{Change, TaskRunner}

  def execute_stage(steps, %{data: keys, opts: opts}) do
    data = Gatekeeper.lock(opts[:gatekeeper], keys, opts[:read_fun])

    TaskRunner.sim(
      data,
      {__MODULE__, :execute_steps, [[steps: steps]]},
      opts[:supervisor],
      opts
    )
    |> notify_stage_observesrs(opts)
    |> handle_sim_results()
    |> reduce_data(opts[:gatekeeper], opts[:write_fun], keys)
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

  def reduce_data({:error, reasons}, _gatekeeper, _fun, _keys), do: {:error, reasons}

  def reduce_data({:ok, results}, gatekeeper, fun, keys) do
    results = Enum.map(results, fn %{position: position, field: field} -> {position, field} end)

    :ok =
      Gatekeeper.update_multi(gatekeeper, results, fn grid ->
        Enum.reduce(results, grid, &fun.(&2, &1))
      end)

    {:ok, keys}
  end

  def notify_stage_observesrs(%{ok: ok, exit: failed} = results, opts) do
    results
  end

  def notify_step_observesrs(%Change{data: data, changes: changes}) do
  end
end
