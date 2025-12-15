defmodule Ximula.Sim.NotifyTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.Notify

  describe "build_pipeline_notification/1" do
    test "builds none notification" do
      assert Notify.build_pipeline_notification(nil) == :none
      assert Notify.build_pipeline_notification(:none) == :none
    end

    test "builds metric notification" do
      assert Notify.build_pipeline_notification(:metric) == :metric
    end

    test "builds event notification" do
      assert Notify.build_pipeline_notification(:event) == :event
    end

    test "builds event_metric notification" do
      assert Notify.build_pipeline_notification(:event_metric) == :event_metric
    end
  end

  describe "build_stage_notification/1" do
    test "builds none notification when nil" do
      assert Notify.build_stage_notification(nil) == %{all: :none, entity: :none}
    end

    test "builds notification with atom" do
      assert Notify.build_stage_notification(:metric) == %{all: :metric, entity: :none}
    end

    test "builds notification with map" do
      result = Notify.build_stage_notification(%{all: :metric, entity: :event})
      assert result == %{all: :metric, entity: :event}
    end

    test "builds notification with partial map" do
      result = Notify.build_stage_notification(%{all: :metric})
      assert result == %{all: :metric, entity: :none}
    end
  end

  describe "build_step_notification/1" do
    test "builds none notification when nil" do
      assert Notify.build_step_notification(nil) == {:none, nil}
    end

    test "builds notification with entity" do
      assert Notify.build_step_notification({:metric, :my_entity}) == {:metric, :my_entity}
      assert Notify.build_step_notification({:event, {10, 5}}) == {:event, {10, 5}}
    end

    test "raises when entity is nil" do
      assert_raise RuntimeError, "step notifications needs an entity", fn ->
        Notify.build_step_notification({:metric, nil})
      end
    end
  end

  describe "measure_pipeline/2" do
    setup do
      # Attach telemetry handler using module function to avoid performance warning
      handler_id = "test-pipeline-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ximula, :sim, :pipeline, :start],
          [:ximula, :sim, :pipeline, :stop]
        ],
        &__MODULE__.handle_telemetry/4,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "none notification does not emit telemetry" do
      pipeline = %{notify: :none}
      result = Notify.measure_pipeline(pipeline, fn -> :result end)

      assert result == :result
      refute_received {:telemetry, _, _, _}
    end

    test "metric notification emits telemetry span" do
      pipeline = %{notify: :metric, name: "test_pipeline"}
      result = Notify.measure_pipeline(pipeline, fn -> :result end)

      assert result == :result

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :start], %{},
                       %{name: "test_pipeline"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stop], %{duration: duration},
                       _metadata}

      assert is_integer(duration)
    end
  end

  describe "measure_stage/2" do
    setup do
      handler_id = "test-stage-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ximula, :sim, :pipeline, :stage, :start],
          [:ximula, :sim, :pipeline, :stage, :stop]
        ],
        &__MODULE__.handle_telemetry/4,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "none notification does not emit telemetry" do
      stage = %{notify: %{all: :none}}
      result = Notify.measure_stage(stage, fn -> :result end)

      assert result == :result
      refute_received {:telemetry, _, _, _}
    end

    test "metric notification emits telemetry span" do
      stage = %{notify: %{all: :metric}, name: "test_stage"}
      result = Notify.measure_stage(stage, fn -> :result end)

      assert result == :result

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :start], %{},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :stop], %{duration: _},
                       _metadata}
    end
  end

  describe "measure_entity_stage/2" do
    setup do
      handler_id = "test-entity-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ximula, :sim, :pipeline, :stage, :entity, :start],
          [:ximula, :sim, :pipeline, :stage, :entity, :stop]
        ],
        &__MODULE__.handle_telemetry/4,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "none notification does not emit telemetry" do
      stage = %{notify: %{entity: :none}}
      result = Notify.measure_entity_stage(stage, fn -> :result end)

      assert result == :result
      refute_received {:telemetry, _, _, _}
    end

    test "metric stage entity notification emits telemetry" do
      stage = %{notify: %{entity: :metric}, name: "test_stage"}

      result =
        Notify.measure_entity_stage(stage, fn ->
          42
        end)

      assert result == 42

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :start], %{},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :stop],
                       _measurements, %{stage_name: "test_stage"}}
    end
  end

  describe "measure_step/2" do
    setup do
      handler_id = "test-step-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ximula, :sim, :pipeline, :stage, :step, :start],
          [:ximula, :sim, :pipeline, :stage, :step, :stop]
        ],
        &__MODULE__.handle_telemetry/4,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "none notification does not emit telemetry" do
      step = %{notify: {:none, nil}}
      result = Notify.measure_step(step, fn -> :result end)

      assert result == :result
      refute_received {:telemetry, _, _, _}
    end

    test "metric notification emits telemetry span with entity" do
      step = %{
        notify: {:metric, {10, 5}},
        module: MyModule,
        function: :my_function
      }

      result = Notify.measure_step(step, fn -> :result end)

      assert result == :result

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :start], %{},
                       metadata}

      assert metadata.entity == {10, 5}
      assert metadata.module == MyModule
      assert metadata.function == :my_function

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :stop],
                       %{duration: _}, metadata}

      assert metadata.entity == {10, 5}
    end

    test "metric notification with :single entity" do
      step = %{
        notify: {:metric, :single},
        module: MyModule,
        function: :my_function
      }

      result = Notify.measure_step(step, fn -> :result end)

      assert result == :result

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :start], %{},
                       metadata}

      assert metadata.entity == :single
    end
  end

  describe "logging warnings" do
    import ExUnit.CaptureLog

    test "warns on unknown pipeline notification type" do
      pipeline = %{notify: :unknown}

      log =
        capture_log(fn ->
          Notify.measure_pipeline(pipeline, fn -> :result end)
        end)

      assert log =~ "unknown pipeline notification type :unknown"
    end

    test "warns on unknown stage notification type" do
      stage = %{notify: %{all: :unknown}}

      log =
        capture_log(fn ->
          Notify.measure_stage(stage, fn -> :result end)
        end)

      assert log =~ "unknown stage notification type :unknown"
    end

    test "warns on unknown entity stage notification type" do
      stage = %{notify: %{entity: :unknown}}

      log =
        capture_log(fn ->
          Notify.measure_entity_stage(stage, fn -> :result end)
        end)

      assert log =~ "unknown entity stage notification type :unknown"
    end

    test "warns on unknown step notification type" do
      step = %{notify: {:unknown, :entity}}

      log =
        capture_log(fn ->
          Notify.measure_step(step, fn -> :result end)
        end)

      assert log =~ "unknown notification type :unknown"
    end
  end

  # Telemetry handler - module function to avoid performance warning
  def handle_telemetry(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
