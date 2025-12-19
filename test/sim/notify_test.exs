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
      result =
        Notify.build_stage_notification(%{all: :metric, entity: {:event, fn _ -> true end}})

      assert %{all: :metric, entity: {:event, _}} = result
    end

    test "builds notification with partial map" do
      result = Notify.build_stage_notification(%{all: :metric})
      assert result == %{all: :metric, entity: {:none, nil}}
    end
  end

  describe "build_step_notification/1" do
    test "builds none notification when nil" do
      assert Notify.build_step_notification(nil) == {:none, nil}
    end

    test "builds notification with entity" do
      assert {:metric, _} = Notify.build_step_notification({:metric, fn _ -> true end})
      assert {:event, _} = Notify.build_step_notification({:event, fn _ -> true end})
    end

    test "raises when entity is nil" do
      assert_raise RuntimeError, "step notifications needs a filter function", fn ->
        Notify.build_step_notification({:metric, nil})
      end
    end
  end

  describe "measure_pipeline/2" do
    setup do
      start_supervised!({Phoenix.PubSub, name: :pubsub_pipeline})
      Phoenix.PubSub.subscribe(:pubsub_pipeline, "sim:pipeline:test_pipeline")

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

      on_exit(fn ->
        :telemetry.detach(handler_id)
        # Phoenix.PubSub.unsubscribe(:pubsub_pipeline, "sim:pipeline:test_pipeline")
      end)

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

    test "receive pipeline completed event" do
      pipeline = %{notify: :event, name: "test_pipeline", pubsub: :pubsub_pipeline}
      result = Notify.measure_pipeline(pipeline, fn -> :result end)
      assert result == :result
      assert_received {:pipeline_completed, %{result: :result, pipeline_name: "test_pipeline"}}
    end

    test "receive pipeline event and metric" do
      pipeline = %{notify: :event_metric, name: "test_pipeline", pubsub: :pubsub_pipeline}
      result = Notify.measure_pipeline(pipeline, fn -> :result end)
      assert result == :result
      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stop], %{}, %{}}
      assert_received {:pipeline_completed, %{result: :result, pipeline_name: "test_pipeline"}}
    end
  end

  describe "measure_stage/2" do
    setup do
      start_supervised!({Phoenix.PubSub, name: :pubsub_stage})
      :ok = Phoenix.PubSub.subscribe(:pubsub_stage, "sim:pipeline:stage:test_stage")

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

      result =
        Notify.measure_stage(stage, fn ->
          %{ok: [1, 2, 3], failed: [404]}
        end)

      assert result == %{ok: [1, 2, 3], failed: [404]}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :start], %{},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :stop], %{duration: _},
                       %{ok: 3, failed: 1}}
    end

    test "receive stage completed event" do
      stage = %{notify: %{all: :event}, pubsub: :pubsub_stage, name: "test_stage"}

      result =
        Notify.measure_stage(stage, fn ->
          %{ok: [1, 2, 3], failed: [404]}
        end)

      assert result == %{ok: [1, 2, 3], failed: [404]}

      assert_received {:stage_completed,
                       %{result: %{ok: [1, 2, 3], failed: [404]}, stage_name: "test_stage"}}
    end

    test "receive stage event and metric" do
      stage = %{notify: %{all: :event_metric}, pubsub: :pubsub_stage, name: "test_stage"}

      result =
        Notify.measure_stage(stage, fn ->
          %{ok: [1, 2, 3], failed: [404]}
        end)

      assert result == %{ok: [1, 2, 3], failed: [404]}
      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :stop], %{}, %{}}

      assert_received {:stage_completed,
                       %{result: %{ok: [1, 2, 3], failed: [404]}, stage_name: "test_stage"}}
    end
  end

  describe "measure_entity_stage/2" do
    setup do
      start_supervised!({Phoenix.PubSub, name: :pubsub_stage_entity})
      :ok = Phoenix.PubSub.subscribe(:pubsub_stage_entity, "sim:pipeline:stage:test_stage:entity")

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
      stage = %{notify: %{entity: {:none, nil}}}
      result = Notify.measure_entity_stage(stage, 21, fn -> 2 * 21 end)

      assert result == 42
      refute_received {:telemetry, _, _, _}
    end

    test "metric stage entity notification emits telemetry" do
      stage = %{notify: %{entity: {:metric, fn _ -> true end}}, name: "test_stage"}

      result =
        Notify.measure_entity_stage(stage, 21, fn ->
          2 * 21
        end)

      assert result == 42

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :start], %{},
                       %{stage_name: "test_stage"}}

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :stop],
                       _measurements, %{stage_name: "test_stage"}}
    end

    test "metric stage entity notification filters telemetry" do
      stage = %{notify: %{entity: {:metric, fn _ -> false end}}, name: "test_stage"}

      result =
        Notify.measure_entity_stage(stage, 21, fn ->
          2 * 21
        end)

      assert result == 42
      refute_received {:telemetry, _, _, _}
    end

    test "receive entity stage completed event" do
      stage = %{
        notify: %{entity: {:event, fn _ -> true end}},
        pubsub: :pubsub_stage_entity,
        name: "test_stage"
      }

      result =
        Notify.measure_entity_stage(stage, 21, fn ->
          2 * 21
        end)

      assert result == 42
      assert_received {:entity_stage_completed, %{result: 42, stage_name: "test_stage"}}
    end

    test "receive entity stage event and metric" do
      stage = %{
        notify: %{entity: {:event_metric, fn _ -> true end}},
        pubsub: :pubsub_stage_entity,
        name: "test_stage"
      }

      result =
        Notify.measure_entity_stage(stage, 21, fn ->
          2 * 21
        end)

      assert result == 42
      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :entity, :stop], %{}, %{}}
      assert_received {:entity_stage_completed, %{result: 42, stage_name: "test_stage"}}
    end
  end

  describe "measure_step/2" do
    setup do
      start_supervised!({Phoenix.PubSub, name: :pubsub_step})
      :ok = Phoenix.PubSub.subscribe(:pubsub_step, "sim:pipeline:stage:entity:step")

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
      result = Notify.measure_step(step, 21, fn -> 21 * 2 end)

      assert result == 42
      refute_received {:telemetry, _, _, _}
    end

    test "metric notification emits telemetry span with entity" do
      step = %{
        notify: {:metric, fn _ -> true end},
        module: MyModule,
        function: :my_function
      }

      result = Notify.measure_step(step, 21, fn -> 21 * 2 end)

      assert result == 42

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :start], %{},
                       metadata}

      assert metadata.change == 21
      assert metadata.module == MyModule
      assert metadata.function == :my_function

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :stop],
                       %{duration: _}, metadata}

      assert metadata.change == 42
    end

    test "metric notification filters telemetry span with entity" do
      step = %{
        notify: {:metric, fn _ -> false end},
        module: MyModule,
        function: :my_function
      }

      result = Notify.measure_step(step, 21, fn -> 21 * 2 end)
      assert result == 42
      refute_received {:telemetry, _, _, _}
    end

    test "receive step completed event" do
      step = %{
        notify: {:event, fn _ -> true end},
        module: MyModule,
        function: :my_function,
        pubsub: :pubsub_step
      }

      result = Notify.measure_step(step, 21, fn -> 21 * 2 end)
      assert result == 42

      assert_received {:step_completed,
                       %{result: 42, step_function: :my_function, step_module: MyModule}}
    end

    test "receive entity stage event and metric" do
      step = %{
        notify: {:event_metric, fn _ -> true end},
        module: MyModule,
        function: :my_function,
        pubsub: :pubsub_step
      }

      result = Notify.measure_step(step, 21, fn -> 21 * 2 end)
      assert result == 42

      assert_received {:telemetry, [:ximula, :sim, :pipeline, :stage, :step, :stop], %{}, %{}}

      assert_received {:step_completed,
                       %{result: 42, step_function: :my_function, step_module: MyModule}}
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
          Notify.measure_entity_stage(stage, 21, fn -> :result end)
        end)

      assert log =~ "unknown entity stage notification type :unknown"
    end

    test "warns on unknown step notification type" do
      step = %{notify: {:unknown, :entity}}

      log =
        capture_log(fn ->
          Notify.measure_step(step, 21, fn -> 21 * 2 end)
        end)

      assert log =~ "unknown step notification type :unknown"
    end
  end

  # Telemetry handler - module function to avoid performance warning
  def handle_telemetry(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
