defmodule Ximula.Sim.Notify do
  @moduledoc """
  Unified notification system for Telemetry and PubSub events.

  Provides configurable notifications at three levels:
  - Pipeline (entire simulation run)
  - Stage (one stage across all entities)
  - Step (one step for one entity)

  ## Notification Types

  - `:none` - No notifications
  - `:metric` - Telemetry only (duration, counts)
  - `:event` - PubSub only (domain events with payloads)
  - `:event_metric` - Both telemetry and PubSub
  """

  require Logger

  alias Ximula.Sim.Queue

  @telemetry_prefix [:ximula, :sim]

  # --- Build Notification ---

  def build_pipeline_notification(notify), do: build_notification(notify)

  def build_stage_notification(%{} = notify) do
    %{
      all: Map.get(notify, :all) |> build_notification(),
      entity: Map.get(notify, :entity) |> build_notification()
    }
  end

  def build_stage_notification(notify) do
    %{all: build_notification(notify), entity: :none}
  end

  def build_step_notification({_notify, nil}) do
    raise "step notifications needs an entity"
  end

  def build_step_notification({notify, entity}) do
    {build_notification(notify), entity}
  end

  def build_step_notification(nil), do: {:none, nil}

  defp build_notification(nil), do: :none

  defp build_notification(notify)
       when notify in [:none, :metric, :event, :event_metric],
       do: notify

  # --- Queue Notification ---

  def measure_queue(%Queue{name: name, interval: interval}, fun) do
    meta = %{name: name, interval: interval}

    :telemetry.span(
      @telemetry_prefix ++ [:queue],
      meta,
      fn ->
        result = fun.()
        {result, meta}
      end
    )
  end

  # --- Pipeline Notification ---

  def measure_pipeline(%{notify: :none}, fun), do: fun.()

  def measure_pipeline(%{notify: :metric} = pipeline, fun) do
    meta = %{name: Map.get(pipeline, :name)}

    :telemetry.span(
      @telemetry_prefix ++ [:pipeline],
      meta,
      fn ->
        result = fun.()
        {result, meta}
      end
    )
  end

  def measure_pipeline(%{notify: :event} = pipeline, fun) do
    fun.()
    |> broadcast(:pipeline_completed, pipeline)
  end

  def measure_pipeline(%{notify: :event_metric} = pipeline, fun) do
    measure_pipeline(%{pipeline | notify: :metric}, fun)
    |> broadcast(:pipeline_completed, pipeline)
  end

  def measure_pipeline(%{notify: unknown}, fun) do
    Logger.warning("unknown pipeline notification type #{inspect(unknown)}")
    fun.()
  end

  # --- Stage Notification ---

  def measure_stage(%{notify: %{all: :none}}, fun), do: fun.()

  def measure_stage(%{notify: %{all: :metric}} = stage, fun) do
    meta = %{stage_name: Map.get(stage, :name)}

    :telemetry.span(
      @telemetry_prefix ++ [:pipeline, :stage],
      meta,
      fn ->
        result = fun.()
        {result, meta}
      end
    )
  end

  def measure_stage(%{notify: %{all: :event}} = stage, fun) do
    fun.()
    |> broadcast(:stage_completed, stage)
  end

  def measure_stage(%{notify: %{all: :event_metric}} = stage, fun) do
    measure_pipeline(put_in(stage, [:notify, :all], :metric), fun)
    |> broadcast(:stage_completed, stage)
  end

  def measure_stage(%{notify: %{all: unknown}}, fun) do
    Logger.warning("unknown stage notification type #{inspect(unknown)}")
    fun.()
  end

  # --- Entity Stage Notification ---

  def measure_entity_stage(%{notify: %{entity: :none}}, fun), do: fun.()

  def measure_entity_stage(%{notify: %{entity: :metric}} = stage, fun) do
    meta = %{stage_name: Map.get(stage, :name)}

    :telemetry.span(
      @telemetry_prefix ++ [:pipeline, :stage, :entity],
      meta,
      fn ->
        result = fun.()
        {result, meta}
      end
    )
  end

  def measure_entity_stage(%{notify: %{entity: :event}} = stage, fun) do
    fun.()
    |> broadcast(:entity_stage_completed, stage)
  end

  def measure_entity_stage(%{notify: %{entity: :event_metric}} = stage, fun) do
    measure_pipeline(put_in(stage, [:notify, :entity], :metric), fun)
    |> broadcast(:entity_stage_completed, stage)
  end

  def measure_entity_stage(%{notify: %{entity: unknown}}, fun) do
    Logger.warning("unknown entity stage notification type #{inspect(unknown)}")
    fun.()
  end

  # --- Step Notification Strategies ---

  def measure_step(%{notify: {:none, nil}}, fun), do: fun.()

  def measure_step(%{notify: {:metric, entity}} = step, fun) do
    meta = %{entity: entity, module: step.module, function: step.function}

    :telemetry.span(
      @telemetry_prefix ++ [:pipeline, :stage, :step],
      meta,
      fn ->
        result = fun.()
        {result, meta}
      end
    )
  end

  def measure_step(%{notify: {:event, _entity}} = step, fun) do
    fun.()
    |> broadcast(:step_completed, step)
  end

  def measure_step(%{notify: {:event_metric, entity}} = step, fun) do
    measure_step(%{step | notify: {:metric, entity}}, fun)
    |> broadcast(:step_completed, step)
  end

  def measure_step(%{notify: {unknown, entity}}, fun) do
    Logger.warning("unknown notification type #{inspect(unknown)} for entity #{inspect(entity)}")
    fun.()
  end

  # --- PubSub ---

  defp broadcast(result, event, opts) do
    payload = prepare_payload(result, event, opts)
    topic = build_topic(event, payload, opts)
    :ok = Phoenix.PubSub.broadcast(opts[:pubsub], topic, {event, payload})
    result
  end

  defp prepare_payload(result, :pipeline_completed, pipeline),
    do: %{pipeline_name: pipeline.name, result: result}

  defp prepare_payload(result, :stage_completed, stage),
    do: %{stage_name: stage.name, result: result}

  defp prepare_payload(result, :entity_stage_completed, stage),
    do: %{stage_name: stage.name, result: result}

  defp prepare_payload(result, :step_completed, step),
    do: %{step_module: step.module, step_function: step.function, result: result}

  defp build_topic(:pipeline_completed, _payload, pipeline) do
    "sim:pipeline:#{pipeline.name}"
  end

  defp build_topic(:stage_completed, _payload, stage) do
    "sim:pipeline:stage:#{stage.name}"
  end

  defp build_topic(:entity_stage_completed, _payload, stage) do
    "sim:pipeline:stage:#{stage.name}:entity"
  end

  defp build_topic(:step_completed, _payload, _step) do
    "sim:pipeline:stage:entity:step"
  end
end
