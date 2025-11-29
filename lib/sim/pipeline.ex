defmodule Ximula.Sim.Pipeline do
  @moduledoc """
  Defines and executes simulation pipelines with multiple stages and steps.

  A pipeline is a sequence of stages that run in order. Each stage defines:
  - An executor strategy (Single, Grid, or Gatekeeper)
  - A list of simulation steps to run
  - Notification configuration for telemetry and events

  ## Architecture

  ```
  Pipeline (sequential stages)
    └─> Stage (executor + steps)
         └─> Executor (parallel/single)
              └─> Steps (pure functions)

  Example usage:
      import Ximula.Sim.Pipeline
      pipeline =
        new_pipeline(notify: metric, name: "Simple Test Pipeline")
        |> add_stage(executor: GridExecutor, notify: %{entity: event_metric, all: metric}, name: "Vegetation Sim")
        |> add_step(CropSimulation, :check_soil, notify: {:metric, {3, 5}})
        |> add_step(CropSimulation, :grow_plants)
        |> add_stage(executor: SingleExecutor, notify: :metric, name: "Population Sim")
        |> add_step(PopulationSimulation, :consume_food, notify: {:event_metric, {2, 3}})

      initial_state = %{data: root, meta: %{tick: 0}}
      {:ok, final_state} = Ximula.Sim.Pipeline.execute(pipeline, initial_state)
  """

  alias Ximula.Sim.{Change, Notify, TaskRunner}

  # --- Build Pipeline ---

  def new_pipeline(opts \\ []) do
    %{stages: [], notify: Notify.build_stage_notification(opts[:notify]), name: opts[:name]}
  end

  # Add stage (starts new transaction boundary)
  def add_stage(pipeline, opts) do
    stage = %{
      name: opts[:name],
      executor: opts[:executor],
      on_error: opts[:on_error] || :raise,
      notify: Notify.build_stage_notification(opts[:notify]),
      steps: []
    }

    update_in(pipeline.stages, &(&1 ++ [stage]))
  end

  # Add step to current stage
  @spec add_step(map(), any(), any(), nil | maybe_improper_list() | map()) :: map()
  def add_step(pipeline, module, function, opts \\ []) do
    step = %{
      module: module,
      function: function,
      notify: Notify.build_step_notification(opts[:notify])
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
      end)

    {:ok, result.data}
  end

  defp execute_stage(stage, %{data: _data, opts: opts} = result) do
    Notify.measure_stage(stage, fn ->
      case run_stage(stage, result) do
        {:ok, result} ->
          %{data: result, opts: opts}

        {:error, reason} ->
          raise "sim failed with #{inspect(reason)} with #{inspect(opts)}"
      end
    end)
  end

  defp run_stage(%{executor: executor} = stage, %{data: _input_data, opts: opts} = input) do
    data = executor.get_data(input)

    TaskRunner.sim(
      data,
      {__MODULE__, :execute_steps, [[stage: stage]]},
      opts[:supervisor],
      opts
    )
    |> handle_sim_results()
    |> executor.reduce_data(input)
  end

  def execute_steps(data, stage: stage) do
    Notify.measure_entity_stage(stage, fn ->
      Enum.reduce(
        stage.steps,
        %Change{data: data},
        &execute_step/2
      )
      |> Change.reduce()
    end)
  end

  def execute_step(%{module: module, function: function} = step, change) do
    Notify.measure_step(step, fn ->
      apply(module, function, [change])
    end)
  end

  defp handle_sim_results(%{ok: ok, exit: failed}) do
    cond do
      Enum.empty?(ok) ->
        {:error,
         failed
         |> Enum.map(fn {_data, {reason, stacktrace}} ->
           Exception.format_banner(:exit, reason, stacktrace)
         end)}

      Enum.any?(ok) ->
        {:ok, ok}
    end
  end
end
