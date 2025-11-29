defmodule Ximula.Sim.Change do
  @moduledoc """
  Changeset structure for accumulating simulation changes.

  Separates original immutable data from accumulated changes, enabling:
  - Reading from tick N-1 state (immutable)
  - Accumulating changes for tick N (mutable)
  - Steps reading from both original data and prior step changes

  ## Structure

      %Change{
        data: %{health: 100, food: 50},     # Original from tick N-1
        changes: %{health: -10, food: -5}   # Accumulated changes
      }

  ## Usage in Simulation Steps

      def take_damage(%Change{} = change, opts) do
        current_health = Change.get(change, :health)  # 90 (100 - 10)

        if current_health > 0 do
          Change.change_by(change, :health, -20)  # Accumulate -20
        else
          change
        end
      end

  ## Functions

  - `get/2` - Read current value (original + changes)
  - `change_by/3` - Accumulate numeric delta
  - `set/3` - Set absolute numeric value
  - `reduce/1` - Apply all changes to original data

  ## Change Types

  ### Numeric Changes (additive)

      change
      |> Change.change_by(:health, -10)    # health: -10
      |> Change.change_by(:health, -5)     # health: -15
      |> Change.reduce()                   # health: 85 (100 - 15)

  ### Non-numeric Changes (replacement)

      change
      |> Change.set(:status, :dead)        # Last write wins
      |> Change.reduce()

  ## Pattern

  Simulation steps should:
  1. Read from `Change.get/2` (sees accumulated changes)
  2. Accumulate changes via `change_by/3` or `set/3`
  3. Return the modified `%Change{}` struct
  4. Let executors call `reduce/1` at the end

  Example:

      def grow_crops(%Change{} = change) do
        water = Change.get(change, :water)
        growth_rate = calculate_growth(water)

        change
        |> Change.change_by(:growth, growth_rate)
        |> Change.change_by(:water, -1)
      end
  """

  defstruct data: %{}, changes: %{}

  alias Ximula.Sim.Change

  def get(%Change{data: data, changes: changes}, key) do
    case Map.get(data, key) do
      nil -> Map.get(changes, key)
      origin when is_number(origin) -> origin + Map.get(changes, key, 0)
      origin -> Map.get(changes, key) || origin
    end
  end

  def change_by(%Change{changes: changes} = change, key, delta) when is_number(delta) do
    value = Map.get(changes, key, 0)
    %Change{change | changes: Map.put(changes, key, value + delta)}
  end

  def set(%Change{data: data, changes: changes} = result, key, value) when is_number(value) do
    origin = Map.get(data, key, 0)
    changes = Map.put(changes, key, value - origin)
    %{result | changes: changes}
  end

  def reduce(%Change{data: data, changes: changes}) do
    data
    |> Map.keys()
    |> Enum.reduce(data, fn key, data ->
      change = Map.get(changes, key)
      origin = Map.get(data, key)
      Map.put(data, key, reduce_value(origin, change))
    end)
  end

  defp reduce_value(origin, change) when is_number(origin) and is_number(change) do
    origin + change
  end

  defp reduce_value(origin, nil), do: origin

  defp reduce_value(_origin, change), do: change
end
