defmodule Ximula.Sim.Notify do
  @moduledoc """
  Unified notification helper for Telemetry and PubSub.

  Telemetry: Always on, lightweight metrics (duration, counts)
  PubSub: Opt-in, domain events with full payloads
  """

  @telemetry_prefix [:ximula, :sim]

  def build_steps_notification(nil), do: :steps_none

  def build_steps_notification(notify)
      when notify in [:none, :telemetry, :pubsub, :telemetry_pubsub],
      do: "steps_#{notify}" |> String.to_atom()

  def build_step_notification(nil), do: :step_none

  def build_step_notification(notify)
      when notify in [:none, :telemetry, :pubsub, :telemetry_pubsub],
      do: "step_#{notify}" |> String.to_atom()

  def measure_stage(fun, opts) do
    :telemetry.span(@telemetry_prefix ++ [:stage], %{stage_name: opts[:stage_name]}, fn ->
      {fun.(), %{stage_name: opts[:stage_name]}}
    end)
    |> broadcast(:stage_complete, opts)
  end

  def measure_steps(notify, fun) do
    apply(__MODULE__, notify, [fun])
  end

  def failed_steps(failed) do
    :telemetry.execute(
      @telemetry_prefix ++ [:stage, :failed_steps],
      %{failed_count: length(failed)},
      %{}
    )
  end

  def measure_step(step, fun) do
    apply(__MODULE__, step.notify, [step, fun])
  end

  # --- Steps Notification Strategies ---

  def steps_none(fun), do: fun.()

  def steps_telemetry(fun) do
    :telemetry.span(
      @telemetry_prefix ++ [:stage, :all_steps],
      %{},
      {fn -> fun.() end, %{}}
    )
  end

  def steps_pubsub(fun) do
    fun.()
    |> broadcast(:steps_complete, %{})
  end

  def steps_telemetry_pubsub(fun) do
    steps_telemetry(fun)
    |> broadcast(:steps_complete, %{})
  end

  # --- Step Notification Strategies ---

  def step_none(_step, fun), do: fun.()

  def step_telemetry(step, fun) do
    meta = %{name: step.name, module: step.module, function: step.function}

    :telemetry.span(
      @telemetry_prefix ++ [:stage, :step],
      meta,
      {fn -> fun.() end, meta}
    )
  end

  def step_pubsub(step, fun) do
    fun.()
    |> broadcast(:step_complete, step)
  end

  def step_telemetry_pubsub(step, fun) do
    step_telemetry(step, fun)
    |> broadcast(:step_complete, step)
  end

  # --- PubSub ---

  defp broadcast(_result, event, opts) do
    payload = prepare_payload(event, opts)
    topic = build_topic(event, payload, opts)
    :ok = Phoenix.PubSub.broadcast(:TODO_PUB_SUB_NAME, topic, {event, payload})
  end

  defp prepare_payload(:stage_complete, opts), do: %{stage_naem: opts[:stage_name]}
  defp prepare_payload(:steps_complete, _), do: %{}
  defp prepare_payload(:step_complete, step), do: %{module: step.module, function: step.function}

  defp build_topic(:stage_complete, _payload, opts) do
    "sim:#{opts[:sim_name] || :sim}:stage:#{opts[:stage_name]}"
  end

  defp build_topic(:steps_complete, %{step: step}, opts) do
    "sim:#{opts[:sim_name] || :sim}:step:#{step}"
  end

  defp build_topic(:step_complete, %{step: step}, opts) do
    "sim:#{opts[:sim_name] || :sim}:step:#{step}"
  end
end
