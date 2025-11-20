defmodule Ximula.Sim.TaskRunnerTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.TaskRunnerTest
  alias Ximula.Sim.TaskRunner

  def sim_failed(entity) do
    if rem(entity.id, 3) == 0,
      do: raise("upps"),
      else: %{entity | value: entity.value + 10}
  end

  def sim_changed(entity) do
    if rem(entity.id, 2) == 0,
      do: %{entity | value: entity.value + 10},
      else: :no_change
  end

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: Sim.TaskRunner.Task.Supervisor})
    %{supervisor: supervisor}
  end

  test "returns results grouped by success and failed", %{supervisor: supervisor} do
    entities = 1..6 |> Enum.map(&%{id: &1, value: &1})
    results = TaskRunner.sim(entities, {TaskRunnerTest, :sim_failed, []}, supervisor)

    assert Enum.map(results.ok, & &1.id) |> Enum.sort() == [1, 2, 4, 5]
    assert Enum.member?(results.ok, %{id: 1, value: 11})
    assert Enum.member?(results.ok, %{id: 5, value: 15})
    assert Enum.map(results.exit, fn {entity, _reason} -> entity.id end) |> Enum.sort() == [3, 6]
  end

  test "returns only changed entities", %{supervisor: supervisor} do
    entities = 1..6 |> Enum.map(&%{id: &1, value: &1})
    results = TaskRunner.sim(entities, {TaskRunnerTest, :sim_changed, []}, supervisor)

    assert Enum.map(results.ok, & &1.id) |> Enum.sort() == [2, 4, 6]
    assert Enum.member?(results.ok, %{id: 6, value: 16})
    assert Enum.member?(results.ok, %{id: 2, value: 12})
    assert Enum.empty?(results.exit)
  end
end
