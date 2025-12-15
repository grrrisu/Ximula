defmodule Ximula.Sim.ChangeTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.Change

  test "get nil" do
    change = %Change{data: %{counter: nil}}
    assert Change.get(change, :counter) == nil
  end

  test "get number" do
    change = %Change{data: %{counter: 5}}
    assert Change.get(change, :counter) == 5
  end

  test "get anything" do
    change = %Change{data: %{foo: {"bar", "baz"}}}
    assert Change.get(change, :foo) == {"bar", "baz"}
  end

  test "change by value" do
    change = %Change{data: %{counter: 5}}
    change = Change.change_by(change, :counter, 1)
    assert Change.get(change, :counter) == 6
    change = Change.change_by(change, :counter, 2)
    assert Change.get(change, :counter) == 8
  end

  test "set value" do
    change = %Change{data: %{counter: 5}}
    change = Change.set(change, :counter, 10)
    assert Change.get(change, :counter) == 10
    change = Change.set(change, :counter, 20)
    assert Change.get(change, :counter) == 20
  end

  test "set new value" do
    change = %Change{data: %{counter: 5}}
    change = Change.set(change, :counter, 10)
    assert Change.get(change, :counter) == 10
    change = Change.set(change, :step, 5)
    assert Change.get(change, :step) == 5
  end

  describe "nested structure" do
    test "get nested value" do
      value = Change.get(%Change{data: %{field: %{vegetation: 5}}}, [:field, :vegetation])
      assert value == 5
    end

    test "set nested value" do
      change = Change.set(%Change{data: %{field: %{vegetation: 5}}}, [:field, :vegetation], 10)
      value = Change.get(change, [:field, :vegetation])
      assert value == 10
    end

    test "change nested value" do
      change =
        Change.change_by(%Change{data: %{field: %{vegetation: 5}}}, [:field, :vegetation], -2)

      value = Change.get(change, [:field, :vegetation])
      assert value == 3
    end
  end

  test "reduce changes" do
    change = %Change{
      data: %{counter: 5, new_stuff: nil, foo: "bar", read: :only},
      changes: %{counter: 2, temp: 4, new_stuff: 7, foo: "baz"}
    }

    result = Change.reduce(change)
    assert result == %{counter: 7, new_stuff: 7, foo: "baz", read: :only}
  end

  test "reduce changes with nested structure" do
    change = %Change{
      data: %{field: %{vegetation: 5, water: %{quality: 5, amount: 10}}, tick: 42},
      changes: %{
        field: %{vegetation: 3, soil: 7, water: %{amount: -3}},
        tick: 1,
        position: {0, 0}
      }
    }

    result = Change.reduce(change)
    assert result == %{field: %{vegetation: 8, water: %{quality: 5, amount: 7}}, tick: 43}
  end
end
