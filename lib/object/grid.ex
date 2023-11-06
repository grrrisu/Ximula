defmodule Ximula.Grid do
  @moduledoc """
  2 dimensional grid with boundary check
  """

  alias Ximula.Grid

  def create(width, height, default \\ nil)

  def create(width, height, func) when is_function(func) do
    0..(width - 1)
    |> Map.new(fn x ->
      {x,
       0..(height - 1)
       |> Map.new(fn y ->
         {y, func.(x, y)}
       end)}
    end)
  end

  def create(width, height, [[_c | _] | _r] = list) do
    Grid.create(width, height, fn x, y ->
      list |> Enum.at(height - (y + 1)) |> Enum.at(x)
    end)
  end

  def create(width, height, value) do
    Grid.create(width, height, fn _x, _y -> value end)
  end

  def apply_changes(grid, changes) do
    Enum.reduce(changes, grid, fn {{x, y}, value}, grid ->
      Grid.put(grid, x, y, value)
    end)
  end

  def get(nil, _x, _y), do: {:error, "grid is nil"}

  def get(%{0 => columns} = grid, x, y)
      when x >= 0 and x < map_size(grid) and y >= 0 and y < map_size(columns) do
    get_in(grid, [x, y])
  end

  def get(grid, x, y) when is_integer(x) and is_integer(y) do
    {:error,
     "coordinates x: #{x}, y: #{y} outside of grid width: #{width(grid)}, height: #{height(grid)}"}
  end

  def get(_grid, x, y) do
    {:error, "only integers are allowed as coordinates, x: #{x}, y: #{y}"}
  end

  def put(%{0 => columns} = grid, x, y, value)
      when x >= 0 and x < map_size(grid) and y >= 0 and y < map_size(columns) do
    put_in(grid, [x, y], value)
  end

  def put(grid, x, y, _value) when is_integer(x) and is_integer(y) do
    {:error,
     "coordinates x: #{x}, y: #{y} outside of grid width: #{width(grid)}, height: #{height(grid)}"}
  end

  def put(_grid, x, y, _value) do
    {:error, "only integers are allowed as coordinates, x: #{x}, y: #{y}"}
  end

  def width(grid) do
    map_size(grid)
  end

  def height(grid) do
    map_size(grid[0])
  end

  # return the grid as a list
  # note: the order of the values may be in random order
  def values(grid) do
    map(grid, fn _x, _y, value -> value end)
  end

  # return the grid as a list
  # note: the order of the values may be in random order
  def positions_and_values(grid) do
    map(grid, fn x, y, value -> {{x, y}, value} end)
  end

  # return the grid as a list
  # note: the order of the values may be in random order
  def map(grid, func \\ &{&1, &2, &3}) do
    Enum.map(grid, fn {x, col} ->
      Enum.map(col, fn {y, value} ->
        func.(x, y, value)
      end)
    end)
    |> List.flatten()
  end

  @spec sorted_list(any()) :: list()
  def sorted_list(grid), do: sorted_list(grid, :asc)

  def sorted_list(grid, :asc) do
    grid
    |> positions_and_values()
    |> Enum.sort_by(fn {{x, y}, _v} -> {y, x} end)
  end

  def sorted_list(grid, :cartesian) do
    grid
    |> positions_and_values()
    |> Enum.sort_by(fn {{x, y}, _v} -> {-y, x} end)
  end

  # note: the order of the values may be in random
  def filter(grid, func) do
    Enum.map(grid, fn {x, col} ->
      Enum.filter(col, fn {y, value} ->
        func.(x, y, value)
      end)
      |> Enum.map(&(&1 |> Tuple.to_list() |> List.last()))
    end)
    |> List.flatten()
  end

  def merge_field(grid, x, y, value, func \\ &Map.merge(&1, &2)) do
    field = Grid.get(grid, x, y)
    Grid.put(grid, x, y, func.(field, value))
  end
end
