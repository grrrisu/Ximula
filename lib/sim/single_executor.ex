defmodule Ximula.Sim.SingleExecutor do
  alias Ximula.Simulator
  alias Ximula.Sim.Change

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
      %Change{data: data},
      fn %{module: module, function: function}, change ->
        change = apply(module, function, [change])
        notify_step_observesrs(change)
        change
      end
    )
    |> Change.reduce()

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

  def notify_step_observesrs(%Change{data: data, changes: changes}) do
  end
end
