defmodule Ximula.Sim.StageAdapter.GatekeeperTest do
  use ExUnit.Case, async: true

  alias Ximula.Grid

  alias Ximula.Gatekeeper.Server, as: GatekeeperServer
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper

  alias Ximula.Sim.{Change, Pipeline}
  alias Ximula.Sim.StageAdapter.Gatekeeper, as: GatekeeperAdapter

  def get_field(position, gatekeeper) do
    field = Gatekeeper.lock(gatekeeper, position, &Grid.get(&1, position))
    %{position: position, field: field}
  end

  def put_field(%{position: position, field: field}, gatekeeper) do
    :ok = Gatekeeper.update(gatekeeper, position, field, &Grid.put(&1, position, field))
    position
  end

  def inc_counter(%Change{} = change) do
    field = Change.get(change, :field)
    {x, y} = Change.get(change, :position)
    Change.set(change, :field, field + x + y)
  end

  setup do
    data = Grid.create(2, 5, fn x, y -> 10 * x + y end)
    {:ok, agent} = start_supervised({Agent, fn -> data end})
    {:ok, gatekeeper} = start_supervised({GatekeeperServer, [context: %{agent: agent}]})
    {:ok, supervisor} = start_supervised(Task.Supervisor)

    %{supervisor: supervisor, gatekeeper: gatekeeper}
  end

  test "executes grid stage with single step", %{supervisor: supervisor, gatekeeper: gatekeeper} do
    initial_state = %{
      data: Gatekeeper.get(gatekeeper, &Grid.positions(&1)),
      opts: [
        tick: 0,
        supervisor: supervisor
      ]
    }

    pipeline =
      Pipeline.new_pipeline()
      |> Pipeline.add_stage(
        adapter: GatekeeperAdapter,
        gatekeeper: gatekeeper,
        read_fun: &get_field/2,
        write_fun: &put_field/2
      )
      |> Pipeline.add_step(__MODULE__, :inc_counter)
      |> Pipeline.add_step(__MODULE__, :inc_counter)

    {:ok, keys} = Pipeline.execute(pipeline, initial_state)
    assert keys |> length() == Gatekeeper.get(gatekeeper, &Grid.positions(&1)) |> length()

    assert Gatekeeper.get(gatekeeper, &Grid.get(&1, 0, 0)) == 0
    assert Gatekeeper.get(gatekeeper, &Grid.get(&1, 0, 2)) == 2 + 2 + 2
    assert Gatekeeper.get(gatekeeper, &Grid.get(&1, 1, 4)) == 14 + 5 + 5
  end
end
