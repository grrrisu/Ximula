defmodule Ximula.Sim.PipelineTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.{Change, Pipeline, SingleExecutor}

  describe "building pipelines" do
    test "creates empty pipeline" do
      pipeline = Pipeline.new_pipeline()
      assert pipeline.stages == []
    end

    test "adds single stage" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)

      assert length(pipeline.stages) == 1
      assert hd(pipeline.stages).executor == SingleExecutor
      assert hd(pipeline.stages).steps == []
    end

    test "adds multiple stages" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_stage(executor: SingleExecutor)

      assert length(pipeline.stages) == 2
    end

    test "adds steps to current stage" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_step(CropSimulator, :check_soil)
        |> Pipeline.add_step(CropSimulator, :grow_plants)

      stage = hd(pipeline.stages)
      assert length(stage.steps) == 2
      assert Enum.at(stage.steps, 0).function == :check_soil
      assert Enum.at(stage.steps, 1).function == :grow_plants
    end

    test "steps added to correct stage" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_step(CropSimulator, :check_soil)
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_step(PopulationSimulator, :consume_food)

      assert length(Enum.at(pipeline.stages, 0).steps) == 1
      assert length(Enum.at(pipeline.stages, 1).steps) == 1
    end

    test "configures stage options" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(
          executor: SingleExecutor,
          reducer: SimpleReducer,
          on_error: :continue
        )

      stage = hd(pipeline.stages)
      assert stage.executor == SingleExecutor
      assert stage.reducer == SimpleReducer
      assert stage.on_error == :continue
    end
  end

  def inc_counter(%Change{} = change) do
    Change.change_by(change, :counter, 1)
  end

  def add_multiplier(%Change{} = change) do
    Change.set(change, :multiplier, 3)
  end

  def multiply_counter(%Change{} = change) do
    counter = Change.get(change, :counter)
    multiplier = Change.get(change, :multiplier)
    Change.set(change, :counter, counter * multiplier)
  end

  describe "executing pipelines" do
    setup do
      supervisor = start_supervised!({Task.Supervisor, name: Simulator.Task.Supervisor})
      %{supervisor: supervisor}
    end

    test "executes single stage with single step", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_step(__MODULE__, :inc_counter)

      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.counter == 11
    end

    test "executes single stage with multiple steps", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_step(__MODULE__, :inc_counter)
        |> Pipeline.add_step(__MODULE__, :add_multiplier)
        |> Pipeline.add_step(__MODULE__, :multiply_counter)


      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.counter == (10 + 1) * 3
    end
  end
end
