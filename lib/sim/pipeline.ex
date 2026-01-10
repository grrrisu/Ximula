defmodule Ximula.Sim.Pipeline do
  @moduledoc """
  Defines and executes simulation pipelines with multiple stages and steps.

  A pipeline is a sequence of stages that run in order. Each stage defines:
  - An adapter strategy (Single, Grid, or Gatekeeper)
  - A list of simulation steps to run
  - Notification configuration for telemetry and events

  ## Architecture

  ```
  Pipeline (sequential stages)
    └─> Stage (adapter + steps)
         └─> Adapter (parallel/single)
              └─> Steps (pure functions)

  Example usage:
      import Ximula.Sim.Pipeline
      pipeline =
        new_pipeline(notify: metric, name: "Simple Test Pipeline")
        |> add_stage(adapter: GridAdapter, notify: %{entity: event_metric, all: metric}, name: "Vegetation Sim")
        |> add_step(CropSimulation, :check_soil, notify: {:metric, {3, 5}})
        |> add_step(CropSimulation, :grow_plants)
        |> add_stage(adapter: SingleAdapter, notify: :metric, name: "Population Sim")
        |> add_step(PopulationSimulation, :consume_food, notify: {:event_metric, {2, 3}})
        |> add_stage(adapter: GatekeeperAdapter, notify: %{entity: event_metric, all: metric}, name: "Movement Sim", gatekeeper: :gatekeeper, read_fun: &Movement.get/2, write_fun: &Movement.put/3)
        |> add_step(MoveSimulation, :check_soil, notify: {:metric, {3, 5}})

      initial_state = %{data: root, meta: %{tick: 0}}
      {:ok, final_state} = Ximula.Sim.Pipeline.execute(pipeline, initial_state)
  """

  alias Ximula.Sim.{Change, Notify, TaskRunner}

  # --- Build Pipeline ---

  def new_pipeline(opts \\ []) do
    %{
      stages: [],
      name: opts[:name],
      notify: Notify.build_pipeline_notification(opts[:notify]),
      pubsub: opts[:pubsub] || Application.get_env(:ximula, :pubsub)
    }
  end

  # Add stage (starts new transaction boundary)
  def add_stage(pipeline, opts) do
    stage = %{
      on_error: :raise,
      steps: [],
      notify: Notify.build_stage_notification(nil),
      pubsub: opts[:pubsub] || Application.get_env(:ximula, :pubsub)
    }

    stage =
      Enum.reduce(opts, stage, fn {key, value}, stage ->
        case key do
          :notify -> Map.put(stage, key, Notify.build_stage_notification(value))
          _ -> Map.put(stage, key, value)
        end
      end)

    update_in(pipeline.stages, &(&1 ++ [stage]))
  end

  # Add step to current stage
  def add_step(pipeline, module, function, opts \\ []) do
    step = %{
      module: module,
      function: function,
      notify: Notify.build_step_notification(opts[:notify]),
      pubsub: opts[:pubsub] || Application.get_env(:ximula, :pubsub)
    }

    update_in(pipeline.stages, fn stages ->
      List.update_at(stages, -1, fn stage ->
        update_in(stage.steps, &(&1 ++ [step]))
      end)
    end)
  end

  # --- Execute Pipeline ---

  def execute(pipeline, result) do
    result =
      Notify.measure_pipeline(pipeline, fn ->
        Enum.reduce(pipeline.stages, result, &execute_stage/2)
        |> Map.fetch!(:data)
      end)

    {:ok, result}
  end

  defp execute_stage(%{adapter: adapter} = stage, %{data: _data, opts: opts} = result) do
    case adapter.run_stage(stage, result) do
      {:ok, result} ->
        %{data: result, opts: opts}

      {:error, reason} ->
        raise "sim failed with #{inspect(reason)} with #{inspect(opts)}"
    end
  end

  def run_tasks(data, {module, fun}, stage, opts) do
    Notify.measure_stage(stage, fn ->
      TaskRunner.sim(
        data,
        {module, fun, [stage]},
        opts[:supervisor],
        opts
      )
    end)
    |> handle_sim_results()
  end

  def execute_steps(data, stage) do
    Notify.measure_entity_stage(stage, data, fn ->
      Enum.reduce(
        stage.steps,
        %Change{data: data},
        &execute_step/2
      )
      |> Change.reduce()
    end)
  end

  def execute_step(%{module: module, function: function} = step, %Change{} = change) do
    Notify.measure_step(step, change, fn ->
      apply(module, function, [change])
    end)
  end

  def handle_sim_results(%{ok: ok, exit: failed}) do
    cond do
      Enum.empty?(ok) ->
        {:error,
         failed
         |> Enum.map(fn {_data, error} ->
           case error do
             {reason, stacktrace} -> Exception.format_banner(:exit, reason, stacktrace)
             :shutdown -> :shutdown
           end
         end)}

      Enum.any?(ok) ->
        {:ok, ok}
    end
  end
end
