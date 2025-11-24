defmodule Ximula.Sim.StageExecutor.Single do
  alias Ximula.Sim.{Change, Notify, TaskRunner}

  def execute_stage(steps, %{data: data, opts: opts}) do
    Notify.measure_stage(
      fn ->
        TaskRunner.sim(
          data,
          {__MODULE__, :execute_steps, [[steps: steps, notify: opts[:notify]]]},
          opts[:supervisor],
          opts
        )
        |> notify_stage_observesrs(opts)
        |> handle_sim_results()
        |> reduce_data()
      end,
      opts
    )
  end

  def execute_steps(data, steps: steps, notify: notify) do
    Notify.measure_steps(notify, fn ->
      Enum.reduce(
        steps,
        %Change{data: data},
        fn %{module: module, function: function} = step, change ->
          Notify.measure_step(step, fn ->
            apply(module, function, [change])
          end)
        end
      )
      |> Change.reduce()
    end)
  end

  defp handle_sim_results(%{ok: ok, exit: failed}) do
    cond do
      Enum.empty?(ok) ->
        Notify.failed_steps(failed)

        {:error,
         failed
         |> Enum.map(fn {_data, {reason, stacktrace}} ->
           Exception.format_banner(:exit, reason, stacktrace)
         end)}

      Enum.any?(ok) ->
        {:ok, ok}
    end
  end

  def reduce_data({:error, reasons}), do: {:error, reasons}

  def reduce_data({:ok, results}) do
    {:ok, List.first(results)}
  end

  def notify_stage_observesrs(%{ok: ok, exit: failed} = results, opts) do
    results
  end

  def notify_step_observesrs(%Change{data: data, changes: changes}) do
  end
end
