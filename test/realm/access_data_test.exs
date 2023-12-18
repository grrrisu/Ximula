defmodule Ximula.AccessDataTest do
  use ExUnit.Case, async: true

  alias Ximula.Grid
  alias Ximula.AccessData

  setup do
    data = Grid.create(2, 4, fn x, y -> 10 * x + y end)
    grid = start_supervised!({AccessData, [data: data]})
    supervisor = start_link_supervised!(Task.Supervisor)

    %{data: data, grid: grid, supervisor: supervisor}
  end

  def get({x, y}, grid) do
    AccessData.get_by(grid, &Grid.get(&1, x, y))
  end

  def lock({x, y}, grid) do
    AccessData.lock({x, y}, grid, fn data, {x, y} -> Grid.get(data, x, y) end)
  end

  def lock_list(list, grid) do
    AccessData.lock_list(list, grid, fn data, {x, y} -> Grid.get(data, x, y) end)
  end

  def update({x, y}, value, grid) do
    AccessData.update({x, y}, value, grid, fn data, {x, y}, value ->
      Grid.put(data, x, y, value)
    end)
  end

  def update_list(list, grid) do
    AccessData.update_list(list, grid, fn data, {x, y}, value ->
      Grid.put(data, x, y, value)
    end)
  end

  describe "get" do
    test "get all", %{grid: grid} do
      assert 1 == AccessData.get_by(grid, & &1) |> Grid.get(0, 1)
    end

    test "get with function", %{grid: grid} do
      assert [0, 1, 2, 3] == AccessData.get_by(grid, &Grid.filter(&1, fn _x, _y, v -> v < 10 end))
    end
  end

  describe "update" do
    test "update with passed data", %{grid: grid} do
      assert 12 == lock({1, 2}, grid)
      :ok = update({1, 2}, 24, grid)
      assert 24 == get({1, 2}, grid)
    end

    test "update without getting it exclusively first", %{grid: grid} do
      assert 12 == get({1, 2}, grid)
      {:error, _msg} = update({1, 2}, 24, grid)
      assert 12 == get({1, 2}, grid)
    end
  end

  describe "lock" do
    test "are executed in sequence for one field", %{grid: grid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn _n ->
        Task.async(fn ->
          value = lock({1, 2}, grid)
          Process.sleep(100)
          :ok = update({1, 2}, value + 1, grid)
        end)
      end)
      |> Task.await_many()

      assert 400 <= Time.diff(Time.utc_now(), before, :millisecond)
      assert 16 == get({1, 2}, grid)
    end

    test "are executed in parallel per field", %{grid: grid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn n ->
        Task.async(fn ->
          value = lock({0, n}, grid)
          Process.sleep(100)
          :ok = update({0, n}, value + 1, grid)
        end)
      end)
      |> Task.await_many()

      assert 200 > Time.diff(Time.utc_now(), before, :millisecond)
      assert [1, 2, 3, 4] == AccessData.get_by(grid, &Grid.filter(&1, fn _x, _y, v -> v < 10 end))
    end

    test "get never blocks", %{grid: grid} do
      result =
        [
          Task.async(fn ->
            value = lock({1, 2}, grid)
            Process.sleep(100)
            :ok = update({1, 2}, value + 1, grid)
            get({1, 2}, grid)
          end),
          Task.async(fn ->
            Process.sleep(10)
            get({1, 2}, grid)
          end),
          Task.async(fn ->
            value = lock({1, 2}, grid)
            Process.sleep(100)
            :ok = update({1, 2}, value + 1, grid)
            get({1, 2}, grid)
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [13, 12, 14] = result
    end

    test "remove lock if current client crashes", %{grid: grid, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = lock({1, 2}, grid)
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = lock({1, 2}, grid)
            Process.sleep(100)
            :ok = update({1, 2}, value + 1, grid)
            get({1, 2}, grid)
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [exit: :upps, ok: 13] = result
    end

    test "remove from requests if queued client crashes", %{grid: grid, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = lock({1, 2}, grid)
            Process.sleep(100)
            :ok = update({1, 2}, value + 1, grid)
            get({1, 2}, grid)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = lock({1, 2}, grid)
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = lock({1, 2}, grid)
            Process.sleep(100)
            :ok = update({1, 2}, value + 1, grid)
            get({1, 2}, grid)
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [ok: 13, exit: :upps, ok: 14] = result
    end

    test "timeouted request should not be able to update", %{data: data} do
      grid =
        start_supervised!(
          {AccessData, [name: :fast_access, data: data, max_duration: 50]},
          id: :fast_access
        )

      [
        Task.async(fn ->
          value = lock({1, 2}, grid)
          Process.sleep(100)
          {:error, _msg} = update({1, 2}, value + 10, grid)
        end),
        Task.async(fn ->
          value = lock({1, 2}, grid)
          :ok = update({1, 2}, value + 1, grid)
        end),
        Task.async(fn ->
          value = lock({1, 2}, grid)
          :ok = update({1, 2}, value + 1, grid)
        end)
      ]
      |> Task.await_many()

      assert 14 == get({1, 2}, grid)
    end

    test "release a lock", %{grid: grid} do
      result =
        [
          Task.async(fn ->
            lock({1, 2}, grid)
            Process.sleep(100)
            :ok = AccessData.release([{1, 2}], grid)
            get({1, 2}, grid)
          end),
          Task.async(fn ->
            Process.sleep(10)
            value = lock({1, 2}, grid)
            Process.sleep(10)
            :ok = update({1, 2}, value + 1, grid)
            get({1, 2}, grid)
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [12, 13] = result
    end

    test "release not required lock", %{grid: grid} do
      result =
        [
          Task.async(fn ->
            lock_list([{0, 2}, {1, 2}], grid)
            Process.sleep(100)
            {:error, _msg} = AccessData.release([{0, 0}, {1, 2}], grid)
            get({1, 2}, grid)
          end),
          Task.async(fn ->
            lock_list([{0, 2}, {1, 2}], grid)
            Process.sleep(100)
            :ok = update_list([{{0, 2}, 200}, {{1, 2}, 210}], grid)
            get({1, 2}, grid)
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [12, 210] = result
    end
  end

  describe "update_list" do
    test "get list and update all", %{grid: grid} do
      list = lock_list([{0, 0}, {1, 1}], grid)
      assert [0, 11] = list
      :ok = update_list([{{0, 0}, 100}, {{1, 1}, 111}], grid)
      assert 100 == get({0, 0}, grid)
      assert 111 == get({1, 1}, grid)
    end

    test "if update fails nothing is updated", %{grid: grid} do
      list = lock_list([{0, 0}, {1, 2}], grid)
      assert [0, 12] = list
      {:error, _} = update_list([{{0, 0}, 100}, {{1, 1}, 111}], grid)
      assert 0 == get({0, 0}, grid)
      assert 12 == get({1, 2}, grid)
    end

    test "if update fails the caller is removed", %{grid: grid} do
      list = lock_list([{0, 0}, {1, 2}], grid)
      assert [0, 12] = list
      {:error, _} = update_list([{{0, 0}, 100}, {{1, 1}, 111}], grid)
      {:error, _} = update_list([{{0, 0}, 100}, {{1, 2}, 111}], grid)
      assert 0 == get({0, 0}, grid)
      assert 11 == get({1, 1}, grid)
      assert 12 == get({1, 2}, grid)
    end

    test "partial get and updates", %{grid: grid} do
      list = lock_list([{0, 0}, {1, 1}], grid)
      assert [0, 11] = list
      assert 2 = lock({0, 2}, grid)
      :ok = update_list([{{0, 0}, 100}, {{0, 2}, 200}], grid)
      assert 100 == get({0, 0}, grid)
      assert 200 == get({0, 2}, grid)
      assert 11 == get({1, 1}, grid)
      :ok = update({1, 1}, 111, grid)
      assert 100 == get({0, 0}, grid)
      assert 200 == get({0, 2}, grid)
      assert 111 == get({1, 1}, grid)
    end

    test "lock and update must be in the same process", %{grid: grid} do
      data =
        [{0, 0}, {0, 1}, {0, 2}]
        |> Enum.map(fn item -> Task.async(fn -> lock(item, grid) end) end)
        |> Enum.map(&Task.await/1)

      assert [0, 1, 2] == data
      {:error, _} = update_list([{{0, 0}, 100}, {{0, 1}, 101}, {{0, 2}, 102}], grid)
    end
  end
end
