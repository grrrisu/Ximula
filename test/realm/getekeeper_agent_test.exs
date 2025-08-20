defmodule Ximula.Gatekeeper.AgentTest do
  use ExUnit.Case, async: true

  alias Ximula.Grid
  alias Ximula.Gatekeeper.Server
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper

  setup do
    data = Grid.create(2, 4, fn x, y -> 10 * x + y end)
    {:ok, agent} = start_supervised({Agent, fn -> data end})
    {:ok, pid} = start_supervised({Server, [context: %{agent: agent}]})
    supervisor = start_link_supervised!(Task.Supervisor)

    %{agent: agent, pid: pid, supervisor: supervisor}
  end

  def get(pid, key) do
    Gatekeeper.get(pid, &Grid.get(&1, key))
  end

  def request_lock(pid, key) do
    Gatekeeper.request_lock(pid, key)
  end

  def lock(pid, key) do
    Gatekeeper.lock(pid, key, &Grid.get(&1, &2))
  end

  def update(pid, key, value) do
    Gatekeeper.update(pid, key, value, fn grid, {key, value} ->
      Grid.put(grid, key, value)
    end)
  end

  def update_multi(pid, data) do
    Gatekeeper.update_multi(pid, data, fn grid, data ->
      Enum.reduce(data, grid, fn {key, value}, grid -> Grid.put(grid, key, value) end)
    end)
  end

  def release(pid, key) do
    Gatekeeper.release(pid, key)
  end

  test "get data from the agent", %{pid: pid} do
    value = get(pid, {1, 2})
    assert 12 == value
  end

  test "read multiple fields", %{pid: pid} do
    values = Gatekeeper.get(pid, &Grid.filter(&1, fn x, y, _v -> x == y end))
    assert [0, 11] == values
  end

  test "lock and read", %{pid: pid} do
    value = lock(pid, {1, 2})
    assert 12 == value
  end

  test "lock and read multi", %{pid: pid} do
    values = lock(pid, [{0, 0}, {1, 1}])
    assert [0, 11] == values
  end

  test "lock and update", %{pid: pid} do
    assert {:error, _msg} = update(pid, {1, 2}, 120)
    :ok = request_lock(pid, {1, 2})
    assert :ok == update(pid, {1, 2}, 120)
    assert 120 == get(pid, {1, 2})
  end

  test "lock and update multi", %{pid: pid} do
    :ok = request_lock(pid, [{0, 0}, {1, 1}])
    update_fun = &Enum.reduce(&2, &1, fn {key, value}, grid -> Grid.put(grid, key, value) end)
    data = [{{0, 0}, 100}, {{1, 1}, 111}]
    assert :ok == Gatekeeper.update_multi(pid, data, update_fun)
    assert [100, 111] == Gatekeeper.get(pid, &Grid.filter(&1, fn x, y, _v -> x == y end))
  end

  test "release lock", %{pid: pid} do
    assert {:error, _msg} = Gatekeeper.release(pid, {1, 2})
    :ok = request_lock(pid, {1, 2})
    assert :ok = Gatekeeper.release(pid, {1, 2})
  end

  test "release lock multi", %{pid: pid} do
    :ok = request_lock(pid, [{0, 0}, {1, 1}])
    assert :ok == Gatekeeper.release(pid, [{0, 0}, {1, 1}])
    assert {:error, _msg} = Gatekeeper.release(pid, [{0, 0}, {1, 2}])
  end

  describe "lock" do
    test "are executed in sequence for one field", %{pid: pid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn _n ->
        Task.async(fn ->
          value = lock(pid, {1, 2})
          Process.sleep(100)
          :ok = update(pid, {1, 2}, value + 1)
        end)
      end)
      |> Task.await_many()

      assert 400 <= Time.diff(Time.utc_now(), before, :millisecond)
      assert 16 == get(pid, {1, 2})
    end

    test "are executed in parallel per field", %{pid: pid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn n ->
        Task.async(fn ->
          value = lock(pid, {0, n})
          Process.sleep(100)
          :ok = update(pid, {0, n}, value + 1)
        end)
      end)
      |> Task.await_many()

      assert 200 > Time.diff(Time.utc_now(), before, :millisecond)

      assert [1, 2, 3, 4] ==
               Gatekeeper.get(pid, &Grid.filter(&1, fn _x, _y, v -> v < 10 end))
    end

    test "get never blocks", %{pid: pid} do
      result =
        [
          Task.async(fn ->
            value = lock(pid, {1, 2})
            Process.sleep(100)
            :ok = update(pid, {1, 2}, value + 1)
            get(pid, {1, 2})
          end),
          Task.async(fn ->
            Process.sleep(10)
            get(pid, {1, 2})
          end),
          Task.async(fn ->
            value = lock(pid, {1, 2})
            Process.sleep(100)
            :ok = update(pid, {1, 2}, value + 1)
            get(pid, {1, 2})
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [13, 12, 14] = result
    end

    test "remove lock if current client crashes", %{pid: pid, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _lock = lock(pid, {1, 2})
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = lock(pid, {1, 2})
            Process.sleep(100)
            :ok = update(pid, {1, 2}, value + 1)
            get(pid, {1, 2})
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [exit: :upps, ok: 13] = result
    end

    test "remove from requests if queued client crashes", %{pid: pid, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = lock(pid, {1, 2})
            Process.sleep(100)
            :ok = update(pid, {1, 2}, value + 1)
            get(pid, {1, 2})
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = request_lock(pid, {1, 2})
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = lock(pid, {1, 2})
            Process.sleep(100)
            :ok = update(pid, {1, 2}, value + 1)
            get(pid, {1, 2})
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [ok: 13, exit: :upps, ok: 14] = result
    end

    test "timeouted request should not be able to update", %{agent: agent} do
      pid =
        start_supervised!(
          {Server, [name: :fast_data_access, max_lock_duration: 50, context: %{agent: agent}]},
          id: :fast_data_access
        )

      [
        Task.async(fn ->
          value = lock(pid, {1, 2})
          Process.sleep(100)
          {:error, _msg} = update(pid, {1, 2}, value + 1)
        end),
        Task.async(fn ->
          value = lock(pid, {1, 2})
          :ok = update(pid, {1, 2}, value + 1)
        end),
        Task.async(fn ->
          value = lock(pid, {1, 2})
          :ok = update(pid, {1, 2}, value + 1)
        end)
      ]
      |> Task.await_many()

      assert 14 == get(pid, {1, 2})
    end
  end

  test "release a lock", %{pid: pid} do
    result =
      [
        Task.async(fn ->
          request_lock(pid, {1, 2})
          Process.sleep(100)
          :ok = release(pid, [{1, 2}])
          get(pid, {1, 2})
        end),
        Task.async(fn ->
          Process.sleep(10)
          value = lock(pid, {1, 2})
          Process.sleep(10)
          :ok = update(pid, {1, 2}, value + 1)
          get(pid, {1, 2})
        end)
      ]
      |> Enum.map(&Task.await(&1))

    assert [12, 13] = result
  end

  test "release not required lock", %{pid: pid} do
    result =
      [
        Task.async(fn ->
          request_lock(pid, [{0, 2}, {1, 2}])
          Process.sleep(100)
          {:error, _msg} = release(pid, [{0, 0}, {1, 2}])
          get(pid, {1, 2})
        end),
        Task.async(fn ->
          request_lock(pid, [{0, 2}, {1, 2}])
          Process.sleep(100)
          :ok = update_multi(pid, [{{0, 2}, 200}, {{1, 2}, 210}])
          get(pid, {1, 2})
        end)
      ]
      |> Enum.map(&Task.await(&1))

    assert [12, 210] = result
  end

  describe "update_list" do
    test "get list and update all", %{pid: pid} do
      list = lock(pid, [{0, 0}, {1, 1}])
      assert [0, 11] = list
      :ok = update_multi(pid, [{{0, 0}, 100}, {{1, 1}, 111}])
      assert 100 == get(pid, {0, 0})
      assert 111 == get(pid, {1, 1})
    end

    test "if update fails nothing is updated", %{pid: pid} do
      list = lock(pid, [{0, 0}, {1, 2}])
      assert [0, 12] = list
      {:error, _} = update_multi(pid, [{{0, 0}, 100}, {{1, 1}, 111}])
      assert 0 == get(pid, {0, 0})
      assert 12 == get(pid, {1, 2})
    end

    test "if update fails the caller is removed", %{pid: pid} do
      list = lock(pid, [{0, 0}, {1, 2}])
      assert [0, 12] = list
      {:error, _} = update_multi(pid, [{{0, 0}, 100}, {{1, 1}, 111}])
      {:error, _} = update_multi(pid, [{{0, 0}, 100}, {{1, 2}, 111}])
      assert 0 == get(pid, {0, 0})
      assert 11 == get(pid, {1, 1})
      assert 12 == get(pid, {1, 2})
    end

    test "partial get and updates", %{pid: pid} do
      list = lock(pid, [{0, 0}, {1, 1}])
      assert [0, 11] = list
      assert 2 = lock(pid, {0, 2})
      :ok = update_multi(pid, [{{0, 0}, 100}, {{0, 2}, 200}])
      assert 100 == get(pid, {0, 0})
      assert 200 == get(pid, {0, 2})
      assert 11 == get(pid, {1, 1})
      :ok = update(pid, {1, 1}, 111)
      assert 100 == get(pid, {0, 0})
      assert 200 == get(pid, {0, 2})
      assert 111 == get(pid, {1, 1})
    end

    test "lock and update must be in the same process", %{pid: pid} do
      data =
        [{0, 0}, {0, 1}, {0, 2}]
        |> Enum.map(fn item -> Task.async(fn -> lock(pid, item) end) end)
        |> Enum.map(&Task.await/1)

      assert [0, 1, 2] == data
      {:error, _} = update_multi(pid, [{{0, 0}, 100}, {{0, 1}, 101}, {{0, 2}, 102}])
    end
  end
end
