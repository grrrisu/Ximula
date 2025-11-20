defmodule Ximula.Sim.Pipeline do
  @moduledoc """
  Defines a simulation pipeline with multiple stages and steps.

  Example usage:
      import Ximula.Sim.Pipeline
      pipeline =
        new_pipeline()
        |> add_stage(executor: GridExecutor, reducer: SumReducer)
        |> add_step(CropSimulation, :check_soil)
        |> add_step(CropSimulation, :grow_plants)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(PopulationSimulation, :consume_food)

      initial_state = %{data: root, meta: %{tick: 0}}
      {:ok, final_state} = Ximula.Sim.Pipeline.execute(pipeline, initial_state)
  """
  def new_pipeline, do: %{stages: []}

  # Add stage (starts new transaction boundary)
  def add_stage(pipeline, opts) do
    stage = %{
      executor: opts[:executor],
      reducer: opts[:reducer],
      on_error: opts[:on_error] || :continue,
      steps: []
    }

    update_in(pipeline.stages, &(&1 ++ [stage]))
  end

  # Add step to current stage
  def add_step(pipeline, module, function) do
    step = %{module: module, function: function}

    update_in(pipeline.stages, fn stages ->
      List.update_at(stages, -1, fn stage ->
        update_in(stage.steps, &(&1 ++ [step]))
      end)
    end)
  end

  def execute(%{stages: stages}, %{data: _data, opts: opts} = result) do
    result =
      Enum.reduce(stages, result, fn %{executor: executor, steps: steps}, result ->
        case executor.execute_stage(steps, result) do
          {:ok, result} -> %{data: result, opts: opts}
          {:error, reason} -> raise "sim failed with #{inspect(reason)} with #{inspect(opts)}"
        end
      end)

    {:ok, result.data}
  end
end
