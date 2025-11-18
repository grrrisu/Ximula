defmodule MySimulation do
  # Build pipeline
  def build do
    new_pipeline()
    |> add_stage(executor: GridExecutor, reducer: SumReducer)
    |> add_step(CropSimulation, :check_soil)
    |> add_step(CropSimulation, :grow_plants)
    |> add_stage(executor: SingleExecutor, reducer: MergeReducer)
    |> add_step(PopulationSimulation, :consume_food)
    |> add_step(PopulationSimulation, :grow_population)
  end

  # Constructor
  defp new_pipeline, do: %{stages: []}

  # Add stage (starts new transaction boundary)
  def add_stage(pipeline, opts) do
    stage = %{
      executor: opts[:executor],
      reducer: opts[:reducer],
      on_error: opts[:on_error] || :halt,
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

  # Execute entire pipeline
  def execute(pipeline, initial_state, tick_number) do
    Enum.reduce_while(pipeline.stages, {:ok, initial_state}, fn stage, {:ok, state} ->
      case execute_stage(stage, state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, strategy, rolled_back_state} ->
          handle_error(strategy, rolled_back_state)
      end
    end)
  end

  # Execute single stage (transaction boundary)
  defp execute_stage(stage, state) do
    pre_stage_state = state
    
    try do
      # Executor runs all steps, accumulates changes
      changes = stage.executor.execute_steps(stage.steps, state)
      
      # Reducer aggregates changes
      final_changes = stage.reducer.reduce(changes)
      
      # Apply changes atomically
      new_state = apply_changes(state, final_changes)
      {:ok, new_state}
    rescue
      error -> {:error, stage.on_error, pre_stage_state}
    end
  end
end
