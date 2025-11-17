defmodule Ximula.Sim.Pipeline do
  @moduledoc """
  Defines a simulation pipeline with multiple stages and steps.

  Example usage:
      import Ximula.Sim.Pipeline
      pipeline =
        new_pipeline()
        |> add_stage(executor: GridExecutor, reducer: SumReducer)
        |> add_step(CropSimulator, :check_soil)
        |> add_step(CropSimulator, :grow_plants)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(PopulationSimulator, :consume_food)

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

  def execute(%{stages: stages}, %{data: data, meta: meta} = result) do
    Enum.reduce(stages, result, fn %{executor: executor, steps: steps}, result ->
      executor.execute_stage(steps, result)
    end)
  end

  # ---- claude ---

  # Execute entire pipeline
  def execute(pipeline, initial_state, _tick) do
    Enum.reduce_while(pipeline.stages, {:ok, initial_state}, fn stage, {:ok, state} ->
      case execute_stage(stage, state) do
        {:ok, new_state} ->
          {:cont, {:ok, new_state}}

          # {:error, strategy, rolled_back_state} ->
          #   raise "Error in stage execution: #{inspect(strategy)}"
          #   handle_error(strategy, rolled_back_state)
      end
    end)
  end

  # Execute single stage (transaction boundary)
  defp execute_stage(stage, state) do
    pre_stage_state = state

    try do
      # Executor runs all steps, accumulates changes
      _changes = stage.executor.execute_steps(stage.steps, state)

      # Reducer aggregates changes
      # final_changes = stage.reducer.reduce(changes)

      # Apply changes atomically
      # new_state = apply_changes(state, final_changes)
      new_state = state
      {:ok, new_state}
    rescue
      _error -> {:error, stage.on_error, pre_stage_state}
    end
  end
end
