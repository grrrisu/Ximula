defmodule Ximula.Sim.StageExecutor.GridTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.{Change, Pipeline}
  alias Ximula.Sim.StageExecutor.Grid, as: GridExecutor
  alias Ximula.Grid

  def inc_counter(%Change{} = change) do
    field = Change.get(change, :field)
    {x, y} = Change.get(change, :position)
    Change.set(change, :field, field + x + y)
  end

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: StageExecutor.GridTest.Supervisor})
    %{supervisor: supervisor}
  end

  test "executes grid stage with single step", %{supervisor: supervisor} do
    initial_state = %{
      data: Grid.create(2, 5, fn x, y -> x + y end),
      opts: [tick: 0, supervisor: supervisor]
    }

    pipeline =
      Pipeline.new_pipeline()
      |> Pipeline.add_stage(executor: GridExecutor)
      |> Pipeline.add_step(__MODULE__, :inc_counter)

    {:ok, final_state} = Pipeline.execute(pipeline, initial_state)

    assert Grid.get(final_state, 0, 0) == 0
    assert Grid.get(final_state, 0, 2) == 4
    assert Grid.get(final_state, 1, 4) == 10
  end
end
