defmodule Ximula.Sim.StageAdapter do
  @moduledoc """
  Behaviour for a stage adapter.

  Adapter protocol: run_stage/2

  Example:
  ```
  defmodule MyCustomAdapter do
    @behaviour Ximula.Sim.StageAdapter
    alias Ximula.Sim.Pipeline

    @impl true
    def run_stage(stage, %{data: data, opts: opts}) do
      data
      |> transform_input()
      |> Pipeline.run_tasks({Pipeline, :execute_steps}, stage, opts)
      |> transform_output()
    end

  end
  ```

  Receives:
  - stage: Map with adapter config, steps, notify settings
  - context: Map with :data (entities to process) and :opts (options)

  Returns:
  - {:ok, result} on success
  - {:error, reasons} on failure
  """

  @type stage() :: %{steps: list()}
  @type input() :: %{data: term(), opts: keyword()}

  @callback run_stage(stage :: stage(), opts :: input()) ::
              {:ok, term()} | {:error, term()}
end
