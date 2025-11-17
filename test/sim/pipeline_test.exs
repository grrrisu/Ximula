defmodule Ximula.Sim.PipelineTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.Pipeline
  alias Ximula.Sim.SingleExecutor

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

  describe "executing pipelines" do
    test "executes single stage with single step" do
      initial_state = %{data: %{soil_quality: 100}, meta: %{tick: 0}}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(executor: SingleExecutor)
        |> Pipeline.add_step(CropSimulator, :check_soil)

      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.soil_quality == 90
    end
  end
end
