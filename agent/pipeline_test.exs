defmodule Ximula.Sim.PipelineTest do
  use ExUnit.Case, async: true

  # ============================================================================
  # Test Fixtures - Simple Simulators
  # ============================================================================

  defmodule CropSimulator do
    def step(:check_soil, data, changes, _opts) do
      soil_quality = Map.get(data, :soil_quality, 100)
      %{changes: Map.put(changes, :soil_quality, soil_quality - 10)}
    end

    def step(:apply_water, data, changes, _opts) do
      water = Map.get(changes, :water, Map.get(data, :water, 0))
      %{changes: Map.put(changes, :water, water + 50)}
    end

    def step(:grow_plants, data, changes, _opts) do
      growth = Map.get(data, :crop_growth, 0)
      water = Map.get(changes, :water, Map.get(data, :water, 0))

      # Growth depends on water accumulated in previous step
      new_growth = growth + div(water, 10)
      %{changes: Map.put(changes, :crop_growth, new_growth)}
    end
  end

  defmodule PopulationSimulator do
    def step(:consume_food, data, changes, _opts) do
      population = Map.get(data, :population, 100)
      crops = Map.get(changes, :crop_growth, Map.get(data, :crop_growth, 0))

      food_consumed = min(population, crops)
      %{changes: Map.put(changes, :food_consumed, food_consumed)}
    end

    def step(:grow_population, data, changes, _opts) do
      population = Map.get(data, :population, 100)
      food_consumed = Map.get(changes, :food_consumed, 0)

      # Population grows if well fed
      growth = if food_consumed >= population, do: 10, else: 0
      %{changes: Map.put(changes, :population, population + growth)}
    end
  end

  defmodule FailingSimulator do
    def step(:crash_step, _data, _changes, _opts) do
      raise "Intentional crash for testing rollback"
    end
  end

  # ============================================================================
  # Test Fixtures - Simple Executor
  # ============================================================================

  defmodule SimpleExecutor do
    def execute_steps(steps, state) do
      # For testing: just run steps on single entity
      accumulated_changes = %{}

      changes = Enum.reduce(steps, accumulated_changes, fn step, acc_changes ->
        result = step.module.step(step.function, state, acc_changes, [])
        Map.merge(acc_changes, result.changes)
      end)

      [changes]  # Return as list for consistency with multi-entity
    end
  end

  # ============================================================================
  # Test Fixtures - Simple Reducer
  # ============================================================================

  defmodule SimpleReducer do
    def reduce([changes]), do: changes
    def reduce(changes_list) do
      Enum.reduce(changes_list, %{}, &Map.merge/2)
    end
  end

  # ============================================================================
  # Helper: Pipeline Builder
  # ============================================================================

  defp new_pipeline, do: %{stages: []}

  defp add_stage(pipeline, opts) do
    stage = %{
      executor: opts[:executor],
      reducer: opts[:reducer] || SimpleReducer,
      on_error: opts[:on_error] || :halt,
      steps: []
    }
    update_in(pipeline.stages, &(&1 ++ [stage]))
  end

  defp add_step(pipeline, module, function) do
    step = %{module: module, function: function}
    update_in(pipeline.stages, fn stages ->
      List.update_at(stages, -1, fn stage ->
        update_in(stage.steps, &(&1 ++ [step]))
      end)
    end)
  end

  # ============================================================================
  # Helper: Pipeline Executor
  # ============================================================================

  defp execute(pipeline, initial_state) do
    Enum.reduce_while(pipeline.stages, {:ok, initial_state}, fn stage, {:ok, state} ->
      case execute_stage(stage, state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, strategy, rolled_back_state} ->
          handle_error(strategy, rolled_back_state)
      end
    end)
  end

  defp execute_stage(stage, state) do
    pre_stage_state = state

    try do
      changes_list = stage.executor.execute_steps(stage.steps, state)
      final_changes = stage.reducer.reduce(changes_list)
      new_state = apply_changes(state, final_changes)
      {:ok, new_state}
    rescue
      _error -> {:error, stage.on_error, pre_stage_state}
    end
  end

  defp apply_changes(state, changes) do
    Map.merge(state, changes)
  end

  defp handle_error(:halt, state), do: {:halt, {:error, :halted, state}}
  defp handle_error(:continue, state), do: {:cont, {:ok, state}}

  # ============================================================================
  # Tests: Building Pipelines
  # ============================================================================

  describe "building pipelines" do
    test "creates empty pipeline" do
      pipeline = new_pipeline()

      assert pipeline.stages == []
    end

    test "adds single stage" do
      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)

      assert length(pipeline.stages) == 1
      assert hd(pipeline.stages).executor == SimpleExecutor
      assert hd(pipeline.stages).steps == []
    end

    test "adds multiple stages" do
      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_stage(executor: SimpleExecutor)

      assert length(pipeline.stages) == 2
    end

    test "adds steps to current stage" do
      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)
        |> add_step(CropSimulator, :grow_plants)

      stage = hd(pipeline.stages)
      assert length(stage.steps) == 2
      assert Enum.at(stage.steps, 0).function == :check_soil
      assert Enum.at(stage.steps, 1).function == :grow_plants
    end

    test "steps added to correct stage" do
      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(PopulationSimulator, :consume_food)

      assert length(Enum.at(pipeline.stages, 0).steps) == 1
      assert length(Enum.at(pipeline.stages, 1).steps) == 1
    end

    test "configures stage options" do
      pipeline =
        new_pipeline()
        |> add_stage(
          executor: SimpleExecutor,
          reducer: SimpleReducer,
          on_error: :continue
        )

      stage = hd(pipeline.stages)
      assert stage.executor == SimpleExecutor
      assert stage.reducer == SimpleReducer
      assert stage.on_error == :continue
    end
  end

  # ============================================================================
  # Tests: Executing Pipelines
  # ============================================================================

  describe "executing pipelines" do
    test "executes single stage with single step" do
      initial_state = %{soil_quality: 100}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)

      {:ok, final_state} = execute(pipeline, initial_state)

      assert final_state.soil_quality == 90
    end

    test "executes single stage with multiple steps" do
      initial_state = %{soil_quality: 100, water: 0, crop_growth: 0}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)
        |> add_step(CropSimulator, :apply_water)
        |> add_step(CropSimulator, :grow_plants)

      {:ok, final_state} = execute(pipeline, initial_state)

      # Changes accumulate through steps
      assert final_state.soil_quality == 90
      assert final_state.water == 50
      assert final_state.crop_growth == 5  # 50 water / 10
    end

    test "steps see accumulated changes from previous steps" do
      initial_state = %{crop_growth: 10, water: 20}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :apply_water)  # +50 water = 70
        |> add_step(CropSimulator, :grow_plants)  # 70/10 = 7 growth

      {:ok, final_state} = execute(pipeline, initial_state)

      assert final_state.water == 70
      assert final_state.crop_growth == 17  # 10 + 7
    end

    test "executes multiple stages in sequence" do
      initial_state = %{
        soil_quality: 100,
        water: 0,
        crop_growth: 0,
        population: 100
      }

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :apply_water)
        |> add_step(CropSimulator, :grow_plants)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(PopulationSimulator, :consume_food)
        |> add_step(PopulationSimulator, :grow_population)

      {:ok, final_state} = execute(pipeline, initial_state)

      # Stage 1: crops grow
      assert final_state.crop_growth == 5

      # Stage 2: population fed and grows
      assert final_state.food_consumed == 5
      assert final_state.population == 100  # Not enough food to grow
    end

    test "stages see results from previous stages" do
      initial_state = %{
        water: 0,
        crop_growth: 0,
        population: 10
      }

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :apply_water)
        |> add_step(CropSimulator, :grow_plants)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(PopulationSimulator, :consume_food)
        |> add_step(PopulationSimulator, :grow_population)

      {:ok, final_state} = execute(pipeline, initial_state)

      # Stage 1 produces 5 crops
      # Stage 2 sees those 5 crops and population is well-fed
      assert final_state.food_consumed == 5
      assert final_state.population == 20  # Grew by 10
    end
  end

  # ============================================================================
  # Tests: Transaction Boundaries & Rollback
  # ============================================================================

  describe "transaction boundaries and rollback" do
    test "stage failure rolls back entire stage" do
      initial_state = %{soil_quality: 100, water: 0}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)
        |> add_step(CropSimulator, :apply_water)
        |> add_step(FailingSimulator, :crash_step)

      {:error, :halted, final_state} = execute(pipeline, initial_state)

      # All changes rolled back - state unchanged
      assert final_state.soil_quality == 100
      assert final_state.water == 0
    end

    test "stage failure preserves previous stage changes" do
      initial_state = %{soil_quality: 100, water: 0, population: 100}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)
        |> add_step(CropSimulator, :apply_water)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(PopulationSimulator, :consume_food)
        |> add_step(FailingSimulator, :crash_step)

      {:error, :halted, final_state} = execute(pipeline, initial_state)

      # Stage 1 committed
      assert final_state.soil_quality == 90
      assert final_state.water == 50

      # Stage 2 rolled back
      refute Map.has_key?(final_state, :food_consumed)
    end

    test "on_error: :halt stops execution" do
      initial_state = %{value: 0}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor, on_error: :halt)
        |> add_step(FailingSimulator, :crash_step)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)

      {:error, :halted, final_state} = execute(pipeline, initial_state)

      # Second stage never executed
      refute Map.has_key?(final_state, :soil_quality)
    end

    test "on_error: :continue allows execution to proceed" do
      initial_state = %{soil_quality: 100, water: 0}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor, on_error: :continue)
        |> add_step(FailingSimulator, :crash_step)
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :check_soil)

      {:ok, final_state} = execute(pipeline, initial_state)

      # Stage 2 executed despite stage 1 failure
      assert final_state.soil_quality == 90
    end
  end

  # ============================================================================
  # Tests: Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "executes pipeline with no stages" do
      initial_state = %{value: 42}
      pipeline = new_pipeline()

      {:ok, final_state} = execute(pipeline, initial_state)

      assert final_state == initial_state
    end

    test "executes stage with no steps" do
      initial_state = %{value: 42}

      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)

      {:ok, final_state} = execute(pipeline, initial_state)

      assert final_state == initial_state
    end

    test "handles empty initial state" do
      pipeline =
        new_pipeline()
        |> add_stage(executor: SimpleExecutor)
        |> add_step(CropSimulator, :apply_water)

      {:ok, final_state} = execute(pipeline, %{})

      assert final_state.water == 50
    end
  end
end
