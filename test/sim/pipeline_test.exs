defmodule Ximula.Sim.PipelineTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.{Change, Pipeline}
  alias Ximula.Sim.StageAdapter.Single

  describe "building pipelines" do
    test "creates empty pipeline" do
      pipeline = Pipeline.new_pipeline()
      assert pipeline.stages == []
      assert pipeline.notify == :none
    end

    test "adds single stage" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)

      assert length(pipeline.stages) == 1
      assert hd(pipeline.stages).adapter == Single
      assert hd(pipeline.stages).steps == []
      assert hd(pipeline.stages).notify == %{all: :none, entity: :none}
    end

    test "adds multiple stages" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_stage(adapter: Single)

      assert length(pipeline.stages) == 2
    end

    test "adds steps to current stage" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(CropSimulation, :check_soil)
        |> Pipeline.add_step(CropSimulation, :grow_plants)

      stage = hd(pipeline.stages)
      assert length(stage.steps) == 2
      assert Enum.at(stage.steps, 0).function == :check_soil
      assert Enum.at(stage.steps, 1).function == :grow_plants
    end

    test "steps added to correct stage" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(CropSimulation, :check_soil)
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(PopulationSimulation, :consume_food)

      assert length(Enum.at(pipeline.stages, 0).steps) == 1
      assert length(Enum.at(pipeline.stages, 1).steps) == 1
    end

    test "configures stage options" do
      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(
          adapter: Single,
          on_error: :continue
        )

      stage = hd(pipeline.stages)
      assert stage.adapter == Single
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

  def crash(%Change{}) do
    raise "crash in step"
  end

  describe "executing pipelines" do
    setup do
      supervisor = start_supervised!({Task.Supervisor, name: PipelineTest.Supervisor})
      %{supervisor: supervisor}
    end

    test "executes single stage with single step", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(__MODULE__, :inc_counter)

      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.counter == 11
    end

    test "executes single stage with multiple steps", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(__MODULE__, :inc_counter)
        |> Pipeline.add_step(__MODULE__, :add_multiplier)
        |> Pipeline.add_step(__MODULE__, :multiply_counter)

      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.counter == (10 + 1) * 3
    end

    test "executes multiple stage", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(__MODULE__, :inc_counter)
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(__MODULE__, :add_multiplier)
        |> Pipeline.add_step(__MODULE__, :multiply_counter)

      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.counter == (10 + 1) * 3
    end

    test "crashes stage", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline()
        |> Pipeline.add_stage(adapter: Single)
        |> Pipeline.add_step(__MODULE__, :crash)

      assert_raise(RuntimeError, ~r/sim failed with .*crash in step/, fn ->
        Pipeline.execute(pipeline, initial_state)
      end)
    end
  end

  def handle_telemetry(event, measurements, meta, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, meta})
  end

  describe "telemetry notifications" do
    setup do
      # Attach telemetry handler using module function to avoid performance warning
      handler_id = "test-pipeline-#{:erlang.unique_integer()}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:ximula, :sim, :pipeline, :start],
            [:ximula, :sim, :pipeline, :stop],
            [:ximula, :sim, :pipeline, :stage, :start],
            [:ximula, :sim, :pipeline, :stage, :stop],
            [:ximula, :sim, :pipeline, :stage, :entity, :start],
            [:ximula, :sim, :pipeline, :stage, :entity, :stop],
            [:ximula, :sim, :pipeline, :stage, :step, :start],
            [:ximula, :sim, :pipeline, :stage, :step, :stop]
          ],
          &__MODULE__.handle_telemetry/4,
          %{test_pid: self()}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      supervisor = start_supervised!({Task.Supervisor, name: PipelineTest.Supervisor})
      %{supervisor: supervisor}
    end

    test "default notify options", %{supervisor: supervisor} do
      initial_state = %{data: %{counter: 10}, opts: [tick: 0, supervisor: supervisor]}

      pipeline =
        Pipeline.new_pipeline(notify: :metric, name: "test_pipeline")
        |> Pipeline.add_stage(
          adapter: Single,
          notify: %{all: :metric, entity: :metric},
          name: "test_stage"
        )
        |> Pipeline.add_step(__MODULE__, :inc_counter, notify: {:metric, :counter})

      {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

      assert final_state.counter == 11

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :start], %{},
                       %{name: "test_pipeline"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :start], %{},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :start], %{},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :start], %{},
                       %{
                         function: :inc_counter,
                         module: Ximula.Sim.PipelineTest,
                         entity: :counter
                       }}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :stop],
                       %{duration: _},
                       %{
                         function: :inc_counter,
                         module: Ximula.Sim.PipelineTest,
                         entity: :counter
                       }}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :stop],
                       %{duration: _}, %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :stop], %{duration: _},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stop], %{duration: _},
                       %{name: "test_pipeline"}}
    end
  end
end
