defmodule Ximula.Sim.Notify do
  @moduledoc """
  Unified notification helper for Telemetry and PubSub.

  Telemetry: Always on, lightweight metrics (duration, counts)
  PubSub: Opt-in, domain events with full payloads
  """

  alias Ximula.Sim.Change

  @telemetry_prefix [:ximula, :sim]

  # --- Stage Notifications ---

  def stage_start(opts) do
    meta = stage_meta(opts)
    :telemetry.execute(@telemetry_prefix ++ [:stage, :start], %{}, meta)
    System.monotonic_time()
  end

  def stage_stop(start_time, result, opts) do
    duration = System.monotonic_time() - start_time
    meta = stage_meta(opts) |> Map.merge(result_meta(result))

    :telemetry.execute(
      @telemetry_prefix ++ [:stage, :stop],
      %{duration: duration, entity_count: entity_count(result)},
      meta
    )

    maybe_broadcast(:stage_complete, stage_payload(result, opts), opts)
  end

  # --- Step Notifications ---

  def step(step, fun, opts, entity) do
    {duration, result} = measure(fun)

    meta = step_meta(step, opts, entity)
    :telemetry.execute(@telemetry_prefix ++ [:step, :stop], %{duration: duration}, meta)

    maybe_broadcast(:step_complete, step_payload(step, result, entity, opts), opts)

    result
  end

  # --- Helpers ---

  defp measure(fun) do
    start = System.monotonic_time()
    result = fun.()
    {System.monotonic_time() - start, result}
  end

  defp stage_meta(opts) do
    %{
      stage: opts[:stage_name],
      sim: opts[:sim_name] || :sim
    }
  end

  defp step_meta(step, opts, entity) do
    %{
      stage: opts[:stage_name],
      step: step.function,
      module: step.module,
      entity: entity,
      sim: opts[:sim_name] || :sim
    }
  end

  defp result_meta({:ok, _}), do: %{status: :ok}
  defp result_meta({:error, reason}), do: %{status: :error, reason: reason}

  defp entity_count({:ok, results}) when is_list(results), do: length(results)
  defp entity_count({:ok, _single}), do: 1
  defp entity_count({:error, _}), do: 0

  defp stage_payload({:ok, data}, opts) do
    %{stage: opts[:stage_name], status: :ok, data: data}
  end

  defp stage_payload({:error, reason}, opts) do
    %{stage: opts[:stage_name], status: :error, reason: reason}
  end

  defp step_payload(step, %Change{data: data, changes: changes}, entity, _opts) do
    %{step: step.function, module: step.module, entity: entity, data: data, changes: changes}
  end

  defp step_payload(step, data, entity, _opts) do
    %{step: step.function, module: step.module, entity: entity, data: data}
  end

  # --- PubSub ---

  defp maybe_broadcast(event, payload, opts) do
    with pubsub when not is_nil(pubsub) <- opts[:pubsub],
         true <- event in (opts[:broadcast_events] || []) do
      topic = build_topic(event, payload, opts)
      Phoenix.PubSub.broadcast(pubsub, topic, {event, payload})
    end
  end

  defp build_topic(:stage_complete, _payload, opts) do
    "sim:#{opts[:sim_name] || :sim}:stage:#{opts[:stage_name]}"
  end

  defp build_topic(:step_complete, %{step: step}, opts) do
    "sim:#{opts[:sim_name] || :sim}:step:#{step}"
  end
end
