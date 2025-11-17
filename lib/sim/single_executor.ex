defmodule Ximula.Sim.SingleExecutor do
  alias Ximula.Simulator

  def execute_stage(steps, %{data: data, opts: opts}) do
    # Grid.get_positions
    %{ok: ok, exit: failed} =
      Simulator.sim(
        [data],
        {__MODULE__, :execute_steps, [steps: steps]},
        opts[:supervisor],
        opts
      )

    notify_stage_observesrs(ok, failed, opts)
  end

  def execute_steps(steps, %{data: data, opts: opts}) do
    dbg([steps, data, opts])
    # Gatekeeper.lock data.keys

    Enum.reduce(steps, %{data: data, changes: %{}}, fn %{module: module, function: function},
                                                       result ->
      result = apply(module, function, [result])
      notify_step_observesrs(result)
      result
    end)
    |> reduce_changes()

    # Gatekeeper.update data.keys
  end

  def notify_stage_observesrs(ok, failed, opts) do
  end

  def notify_step_observesrs(%{data: data, changes: changes}) do
  end

  def reduce_changes(%{data: data, changes: changes}) do
  end
end
