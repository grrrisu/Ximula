defmodule Ximula.Sim.Change do

  defstruct data: %{}, changes: %{}

  alias Ximula.Sim.Change

  def get(%Change{data: data, changes: changes}, key) do
    Map.get(data, key, 0) + Map.get(changes, key, 0)
  end

  def change_by(%Change{changes: changes} = change, key, delta) when is_number(delta) do
    value =  Map.get(changes, key, 0)
    %Change{change | changes: Map.put(changes, key, value + delta)}
  end

  def set(%Change{data: data, changes: changes} = result, key, value) when is_number(value) do
    origin = Map.get(data, key, 0)
    changes = Map.put(changes, key, value - origin)
    %{result | changes: changes}
  end

  def reduce(%Change{data: data, changes: changes}) do
    changes
    |> Map.keys()
    |> Enum.reduce(data, fn key, data ->
      change = Map.get(changes, key)
      origin = Map.get(data, key, 0)
      Map.put(data, key, reduce_value(origin, change))
    end)
  end

  defp reduce_value(origin, change) when is_number(origin) and is_number(change) do
    origin + change
  end
end
