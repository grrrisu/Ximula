defmodule Ximula.Sim.SingleExecutor do
  alias Ximula.Simulator

  def execute_stage(steps, %{data: data, opts: opts}) do
    # Grid.get_positions
    Simulator.sim(
      data,
      {__MODULE__, :execute_steps, [[steps: steps]]},
      opts[:supervisor],
      opts
    )
    |> notify_stage_observesrs(opts)
    |> handle_sim_results()
  end

  def execute_steps(data, steps: steps) do
    # Gatekeeper.lock data.keys

    Enum.reduce(
      steps,
      %{data: data, changes: %{}},
      fn %{module: module, function: function}, result ->
        result = apply(module, function, [result])
        notify_step_observesrs(result)
        result
      end
    )
    |> reduce_changes()

    # Gatekeeper.update data.keys
  end

  defp handle_sim_results(%{ok: ok, exit: failed}) do
    cond do
      Enum.empty?(ok) -> {:error, List.first(failed)}
      Enum.any?(ok) -> {:ok, List.first(ok)}
    end
  end

  def notify_stage_observesrs(%{ok: ok, exit: failed} = results, opts) do
    results
  end

  def notify_step_observesrs(%{data: data, changes: changes}) do
  end

  def reduce_changes(%{data: data, changes: changes}) do
    changes
    |> Map.keys()
    |> Enum.reduce(data, fn key, data ->
      change = Map.get(changes, key)
      origin = Map.get(data, key)
      Map.put(data, key, reduce_value(origin, change))
    end)
  end

  defp reduce_value(origin, change) when is_number(origin) and is_number(change) do
    origin + change
  end
end
