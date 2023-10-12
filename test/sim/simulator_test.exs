defmodule Ximula.SimulatorTest do
  use ExUnit.Case

  alias Ximula.SimulatorTest
  alias Ximula.Simulator

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
    supervisor = start_supervised!({Task.Supervisor, name: Simulator.Task.Supervisor})
    %{supervisor: supervisor}
  end

  test "returns results grouped by success and failed", %{supervisor: supervisor} do
    entities = 1..6 |> Enum.map(&%{id: &1, value: &1})
    results = Simulator.sim(entities, {SimulatorTest, :sim_failed, []}, & &1.id, supervisor)

    assert Enum.map(results.ok, & &1.id) == [5, 4, 2, 1]
    assert Enum.member?(results.ok, %{id: 1, value: 11})
    assert Enum.member?(results.ok, %{id: 5, value: 15})
    assert Enum.map(results.exit, fn {id, _reason} -> id end) == [6, 3]
  end

  test "returns only changed entities", %{supervisor: supervisor} do
    entities = 1..6 |> Enum.map(&%{id: &1, value: &1})
    results = Simulator.sim(entities, {SimulatorTest, :sim_changed, []}, & &1.id, supervisor)

    assert Enum.map(results.ok, & &1.id) == [6, 4, 2]
    assert Enum.member?(results.ok, %{id: 6, value: 16})
    assert Enum.member?(results.ok, %{id: 2, value: 12})
    assert Enum.empty?(results.exit)
  end
end
