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

  test "reduce changes" do
    change = %Change{
      data: %{counter: 5, new_stuff: nil, foo: "bar", read: :only},
      changes: %{counter: 2, temp: 4, new_stuff: 7, foo: "baz"}
    }

    result = Change.reduce(change)
    assert result == %{counter: 7, new_stuff: 7, foo: "baz", read: :only}
  end
end
