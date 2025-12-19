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
      entity: Map.get(notify, :entity) |> build_step_notification
    }
  end

  def build_stage_notification(notify) do
    %{all: build_notification(notify), entity: :none}
  end

  def build_step_notification({_notify, nil}) do
    raise "step notifications needs a filter function"
  end

  def build_step_notification({notify, filter}) when is_function(filter) do
    {build_notification(notify), filter}
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

        {result,
         %{
           stage_name: Map.get(stage, :name),
           ok: Map.get(result, :ok) |> List.wrap() |> Enum.count(),
           failed: Map.get(result, :failed) |> List.wrap() |> Enum.count()
         }}
      end
    )
  end

  def measure_stage(%{notify: %{all: :event}} = stage, fun) do
    fun.()
    |> broadcast(:stage_completed, stage)
  end

  def measure_stage(%{notify: %{all: :event_metric}} = stage, fun) do
    measure_stage(put_in(stage, [:notify, :all], :metric), fun)
    |> broadcast(:stage_completed, stage)
  end

  def measure_stage(%{notify: %{all: unknown}}, fun) do
    Logger.warning("unknown stage notification type #{inspect(unknown)}")
    fun.()
  end

  # --- Entity Stage Notification ---

  def measure_entity_stage(%{notify: %{entity: :none}}, _data, fun), do: fun.()

  def measure_entity_stage(%{notify: %{entity: {:metric, filter}}} = stage, data, fun) do
    apply_filter(filter.(data), fun, fn ->
      meta = %{stage_name: Map.get(stage, :name)}

      :telemetry.span(
        @telemetry_prefix ++ [:pipeline, :stage, :entity],
        meta,
        fn ->
          result = fun.()
          {result, meta}
        end
      )
    end)
  end

  def measure_entity_stage(%{notify: %{entity: {:event, filter}}} = stage, data, fun) do
    apply_filter(filter.(data), fun, fn ->
      fun.()
      |> broadcast(:entity_stage_completed, stage)
    end)
  end

  def measure_entity_stage(%{notify: %{entity: {:event_metric, filter}}} = stage, data, fun) do
    apply_filter(filter.(data), fun, fn ->
      measure_entity_stage(
        put_in(stage, [:notify, :entity], {:metric, filter}),
        data,
        fun
      )
      |> broadcast(:entity_stage_completed, stage)
    end)
  end

  def measure_entity_stage(%{notify: %{entity: unknown}}, _data, fun) do
    Logger.warning("unknown entity stage notification type #{inspect(unknown)}")
    fun.()
  end

  # --- Step Notification Strategies ---

  def measure_step(%{notify: {:none, nil}}, _change, fun), do: fun.()

  def measure_step(%{notify: {:metric, filter}} = step, change, fun) do
    apply_filter(filter.(change), fun, fn ->
      meta = %{change: change, module: step.module, function: step.function}

      :telemetry.span(
        @telemetry_prefix ++ [:pipeline, :stage, :step],
        meta,
        fn ->
          result = fun.()
          {result, Map.put(meta, :change, result)}
        end
      )
    end)
  end

  def measure_step(%{notify: {:event, filter}} = step, change, fun) do
    apply_filter(filter.(change), fun, fn ->
      fun.()
      |> broadcast(:step_completed, step)
    end)
  end

  def measure_step(%{notify: {:event_metric, filter}} = step, change, fun) do
    apply_filter(filter.(change), fun, fn ->
      measure_step(%{step | notify: {:metric, filter}}, change, fun)
      |> broadcast(:step_completed, step)
    end)
  end

  def measure_step(%{notify: {unknown, _filter}}, _change, fun) do
    Logger.warning("unknown step notification type #{inspect(unknown)}")
    fun.()
  end

  defp apply_filter(to_measure, direct_fun, measure_fun)
       when is_function(direct_fun) and is_function(measure_fun) do
    if to_measure, do: measure_fun.(), else: direct_fun.()
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
