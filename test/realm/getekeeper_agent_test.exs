defmodule Ximula.Gatekeeper.AgentTest do
  use ExUnit.Case, async: true

  alias Ximula.Grid
  alias Ximula.Gatekeeper.Server
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper

  setup do
    data = Grid.create(2, 4, fn x, y -> 10 * x + y end)
    {:ok, agent} = start_supervised({Agent, fn -> data end})
    {:ok, pid} = start_supervised(Server)
    supervisor = start_link_supervised!(Task.Supervisor)

    %{agent: agent, pid: pid, supervisor: supervisor}
  end

  def get(pid, agent, key) do
    Gatekeeper.get(pid, agent, &Grid.get(&1, key))
  end

  def lock(pid, key) do
    Gatekeeper.lock(pid, key)
  end

  def lock_and_read(pid, agent, key) do
    Gatekeeper.lock_and_read(pid, agent, key, &Grid.get(&1, &2))
  end

  def update(pid, agent, lock) do
    Gatekeeper.update(pid, agent, lock, fn grid, {key, value} ->
      Grid.put(grid, key, value)
    end)
  end

  test "get data from the agent", %{agent: agent, pid: pid} do
    value = get(pid, agent, {1, 2})
    assert 12 == value
  end

  test "read multiple fields", %{agent: agent, pid: pid} do
    values = Gatekeeper.get(pid, agent, &Grid.filter(&1, fn x, y, _v -> x == y end))
    assert [0, 11] == values
  end

  test "lock and read", %{agent: agent, pid: pid} do
    lock = lock_and_read(pid, agent, {1, 2})
    assert 12 == lock.value
  end

  test "lock and read multi", %{agent: agent, pid: pid} do
    locks = lock_and_read(pid, agent, [{0, 0}, {1, 1}])
    assert [0, 11] == Enum.map(locks, & &1.value)
  end

  test "lock and update", %{agent: agent, pid: pid} do
    lock = lock(pid, {1, 2})
    lock = Map.put(lock, :value, 120)

    assert :ok == update(pid, agent, lock)
    assert 120 == get(pid, agent, {1, 2})
  end

  test "lock and update multi", %{agent: agent, pid: pid} do
    locks = lock(pid, [{0, 0}, {1, 1}])
    locks = Enum.map(locks, &Map.put(&1, :value, 100))
    update_fun = &Enum.reduce(&2, &1, fn {key, value}, grid -> Grid.put(grid, key, value) end)

    assert :ok == Gatekeeper.update(pid, agent, locks, update_fun)
    assert [100, 100] == Gatekeeper.get(pid, agent, &Grid.filter(&1, fn x, y, _v -> x == y end))
  end

  test "release lock", %{pid: pid} do
    lock = lock(pid, {1, 2})
    assert :ok = Gatekeeper.release(pid, lock)
  end

  test "release lock multi", %{pid: pid} do
    locks = lock(pid, [{0, 0}, {1, 1}])
    assert :ok == Gatekeeper.release(pid, locks)
  end

  describe "lock" do
    test "are executed in sequence for one field", %{agent: agent, pid: pid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn _n ->
        Task.async(fn ->
          lock = lock_and_read(pid, agent, {1, 2})
          Process.sleep(100)
          lock = Map.put(lock, :value, lock.value + 1)
          :ok = update(pid, agent, lock)
        end)
      end)
      |> Task.await_many()

      assert 400 <= Time.diff(Time.utc_now(), before, :millisecond)
      assert 16 == get(pid, agent, {1, 2})
    end

    test "are executed in parallel per field", %{agent: agent, pid: pid} do
      before = Time.utc_now()

      0..3
      |> Enum.map(fn n ->
        Task.async(fn ->
          lock = lock_and_read(pid, agent, {0, n})
          Process.sleep(100)
          lock = Map.put(lock, :value, lock.value + 1)
          :ok = update(pid, agent, lock)
        end)
      end)
      |> Task.await_many()

      assert 200 > Time.diff(Time.utc_now(), before, :millisecond)

      assert [1, 2, 3, 4] ==
               Gatekeeper.get(pid, agent, &Grid.filter(&1, fn _x, _y, v -> v < 10 end))
    end

    test "get never blocks", %{agent: agent, pid: pid} do
      result =
        [
          Task.async(fn ->
            lock = lock_and_read(pid, agent, {1, 2})
            Process.sleep(100)
            lock = Map.put(lock, :value, lock.value + 1)
            :ok = update(pid, agent, lock)
            get(pid, agent, {1, 2})
          end),
          Task.async(fn ->
            Process.sleep(10)
            get(pid, agent, {1, 2})
          end),
          Task.async(fn ->
            lock = lock_and_read(pid, agent, {1, 2})
            Process.sleep(100)
            lock = Map.put(lock, :value, lock.value + 1)
            :ok = update(pid, agent, lock)
            get(pid, agent, {1, 2})
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [13, 12, 14] = result
    end

    test "remove lock if current client crashes", %{
      agent: agent,
      pid: pid,
      supervisor: supervisor
    } do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _lock = lock_and_read(pid, agent, {1, 2})
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            lock = lock_and_read(pid, agent, {1, 2})
            Process.sleep(100)
            lock = Map.put(lock, :value, lock.value + 1)
            :ok = update(pid, agent, lock)
            get(pid, agent, {1, 2})
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [exit: :upps, ok: 13] = result
    end
  end
end
