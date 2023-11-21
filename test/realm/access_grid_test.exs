defmodule Ximula.AccessGridTest do
  use ExUnit.Case, async: true

  alias Ximula.Grid
  alias Ximula.AccessGrid

  setup do
    agent = start_supervised!({Agent, fn -> Grid.create(2, 4, fn x, y -> 10 * x + y end) end})
    grid = start_supervised!({AccessGrid, [agent: agent]})
    supervisor = start_link_supervised!(Task.Supervisor)

    %{agent: agent, grid: grid, supervisor: supervisor}
  end

  describe "get" do
    test "get all", %{grid: grid} do
      assert 1 == AccessGrid.get_all(grid) |> Grid.get(0, 1)
    end

    test "get position", %{grid: grid} do
      assert 2 == AccessGrid.get({0, 2}, grid)
    end

    test "get with function", %{grid: grid} do
      assert [0, 1, 2, 3] == AccessGrid.get(&Grid.filter(&1, fn _x, _y, v -> v < 10 end), grid)
    end
  end

  describe "update" do
    test "update with passed data", %{grid: grid} do
      assert 12 == AccessGrid.get!({1, 2}, grid)
      :ok = AccessGrid.update({1, 2}, 24, grid)
      assert 24 == AccessGrid.get({1, 2}, grid)
    end

    test "update without getting it exclusively first", %{grid: grid} do
      assert 12 == AccessGrid.get({1, 2}, grid)
      {:error, _msg} = AccessGrid.update({1, 2}, 24, grid)
      assert 12 == AccessGrid.get({1, 2}, grid)
    end
  end

  describe "get!" do
    test "are executed in sequence for one field", %{grid: grid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn _n ->
        Task.async(fn ->
          value = AccessGrid.get!({1, 2}, grid)
          Process.sleep(100)
          :ok = AccessGrid.update({1, 2}, value + 1, grid)
        end)
      end)
      |> Task.await_many()

      assert 400 <= Time.diff(Time.utc_now(), before, :millisecond)
      assert 16 == AccessGrid.get({1, 2}, grid)
    end

    test "are executed in parallel per field", %{grid: grid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn n ->
        Task.async(fn ->
          value = AccessGrid.get!({0, n}, grid)
          Process.sleep(100)
          :ok = AccessGrid.update({0, n}, value + 1, grid)
        end)
      end)
      |> Task.await_many()

      assert 200 > Time.diff(Time.utc_now(), before, :millisecond)
      assert [1, 2, 3, 4] == AccessGrid.get(&Grid.filter(&1, fn _x, _y, v -> v < 10 end), grid)
    end

    test "get never blocks", %{grid: grid} do
      result =
        [
          Task.async(fn ->
            value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(100)
            :ok = AccessGrid.update({1, 2}, value + 1, grid)
            AccessGrid.get({1, 2})
          end),
          Task.async(fn ->
            Process.sleep(10)
            AccessGrid.get({1, 2})
          end),
          Task.async(fn ->
            value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(100)
            :ok = AccessGrid.update({1, 2}, value + 1, grid)
            AccessGrid.get({1, 2})
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [13, 12, 14] = result
    end

    test "remove lock if current client crashes", %{grid: grid, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(100)
            :ok = AccessGrid.update({1, 2}, value + 1, grid)
            AccessGrid.get({1, 2})
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
            value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(100)
            :ok = AccessGrid.update({1, 2}, value + 1, grid)
            AccessGrid.get({1, 2})
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = AccessGrid.get!({1, 2}, grid)
            Process.sleep(100)
            :ok = AccessGrid.update({1, 2}, value + 1, grid)
            AccessGrid.get({1, 2})
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [ok: 13, exit: :upps, ok: 14] = result
    end

    test "timeouted request should not be able to update", %{agent: agent} do
      grid =
        start_supervised!(
          {AccessGrid, [name: :fast_access, agent: agent, max_duration: 50]},
          id: :fast_access
        )

      [
        Task.async(fn ->
          value = AccessGrid.get!({1, 2}, grid)
          Process.sleep(100)
          {:error, _msg} = AccessGrid.update({1, 2}, value + 10, grid)
        end),
        Task.async(fn ->
          value = AccessGrid.get!({1, 2}, grid)
          :ok = AccessGrid.update({1, 2}, value + 1, grid)
        end),
        Task.async(fn ->
          value = AccessGrid.get!({1, 2}, grid)
          :ok = AccessGrid.update({1, 2}, value + 1, grid)
        end)
      ]
      |> Task.await_many()

      assert 14 == AccessGrid.get({1, 2})
    end

    #   test "release exclusive lock", %{grid: grid} do
    #     result =
    #       [
    #         Task.async(fn ->
    #           AccessGrid.get!(grid)
    #           Process.sleep(100)
    #           :ok = AccessGrid.release(grid)
    #           AccessGrid.get()
    #         end),
    #         Task.async(fn ->
    #           value = AccessGrid.get!(grid)
    #           Process.sleep(100)
    #           :ok = AccessGrid.update(grid, value + 1)
    #           AccessGrid.get()
    #         end)
    #       ]
    #       |> Enum.map(&Task.await(&1))

    #     assert [42, 43] = result
    #   end
  end
end
