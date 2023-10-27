defmodule Ximula.GridTest do
  use ExUnit.Case, async: true

  alias Ximula.Grid

  test "create a new grid" do
    grid = Grid.create(2, 3)
    assert %{0 => %{0 => nil, 1 => nil, 2 => nil}, 1 => %{0 => nil, 1 => nil, 2 => nil}} = grid
  end

  test "create a new grid with 0 as default" do
    grid = Grid.create(2, 3, 0)
    assert %{0 => %{0 => 0, 1 => 0, 2 => 0}, 1 => %{0 => 0, 1 => 0, 2 => 0}} = grid
  end

  test "create a new grid with a function" do
    grid = Grid.create(2, 3, fn x, y -> x + y end)
    assert 3 == Grid.get(grid, 1, 2)
  end

  test "create a new grid from a list" do
    list = [
      [0, 2, 3],
      [4, 5, 6],
      [7, 8, 9]
    ]

    grid = Grid.create(3, 3, list)
    assert 7 == Grid.get(grid, 0, 0)
    assert 3 == Grid.get(grid, 2, 2)
  end

  test "set and read from grid" do
    grid = Grid.create(2, 3)
    assert nil == Grid.get(grid, 1, 2)
    new_grid = Grid.put(grid, 1, 2, "value")
    assert "value" == Grid.get(new_grid, 1, 2)
  end

  test "read outside of grid" do
    grid = Grid.create(2, 3, "one")
    assert {:error, _msg} = Grid.get(grid, 3, 2)
  end

  test "put outside of grid" do
    grid = Grid.create(2, 3)
    assert {:error, _msg} = Grid.put(grid, 3, 2, "one")
  end

  test "read with invalid coordinates" do
    grid = Grid.create(2, 3, "one")
    assert {:error, _msg} = Grid.get(grid, "two", "one")
  end

  test "write with invalid coordinates" do
    grid = Grid.create(2, 3, "one")
    assert {:error, _msg} = Grid.put(grid, "two", "one", "foo")
  end

  test "width" do
    grid = Grid.create(6, 3, "one")
    assert 6 == Grid.width(grid)
  end

  test "height" do
    grid = Grid.create(6, 3, "one")
    assert 3 == Grid.height(grid)
  end

  test "values" do
    grid = Grid.create(2, 2, fn x, y -> {x, y} end)
    assert [{0, 0}, {0, 1}, {1, 0}, {1, 1}] = Grid.values(grid)
  end

  test "position_and_values" do
    grid = Grid.create(2, 2, fn x, y -> x + y end)
    assert [{0, 0, 0}, {0, 1, 1}, {1, 0, 1}, {1, 1, 2}] = Grid.position_and_values(grid)
  end

  test "filter" do
    grid = Grid.create(2, 3, fn x, y -> %{sum: x + y} end)
    results = Grid.filter(grid, fn x, y, _v -> rem(x, 2) == 0 && rem(y, 2) == 0 end)
    assert [%{sum: 0}, %{sum: 2}] = results
  end

  test "map grid" do
    grid = Grid.create(2, 3, fn x, y -> x + y end)

    expected = [
      {0, 0, 0},
      {0, 1, 1},
      {0, 2, 2},
      {1, 0, 1},
      {1, 1, 2},
      {1, 2, 3}
    ]

    assert ^expected = Grid.map(grid, fn x, y, v -> {x, y, v} end)
  end

  test "asc sorted_list" do
    grid = Grid.create(100, 50, 1) |> Grid.sorted_list()
    assert {0, 0, 1} == Enum.at(grid, 0)
    assert {1, 0, 1} == Enum.at(grid, 1)
    assert {2, 0, 1} == Enum.at(grid, 2)
    assert {0, 1, 1} == Enum.at(grid, 100)
    assert {0, 2, 1} == Enum.at(grid, 200)
    assert {0, 3, 1} == Enum.at(grid, 300)
    assert {99, 49, 1} == Enum.at(grid, 4999)
  end

  test "cart sorted_list" do
    grid = Grid.create(100, 50, 1) |> Grid.sorted_list(:cartesian)
    assert {0, 49, 1} == Enum.at(grid, 0)
    assert {1, 49, 1} == Enum.at(grid, 1)
    assert {2, 49, 1} == Enum.at(grid, 2)
    assert {0, 48, 1} == Enum.at(grid, 100)
    assert {0, 47, 1} == Enum.at(grid, 200)
    assert {0, 46, 1} == Enum.at(grid, 300)
    assert {99, 0, 1} == Enum.at(grid, 4999)
  end

  test "merge field" do
    grid = Grid.create(1, 2, %{some_value: 3})
    grid = Grid.merge_field(grid, 0, 0, %{some_value: 0})
    grid = Grid.merge_field(grid, 0, 1, %{other_value: 5})
    assert %{some_value: 0} = Grid.get(grid, 0, 0)
    assert %{other_value: 5, some_value: 3} = Grid.get(grid, 0, 1)
  end
end
