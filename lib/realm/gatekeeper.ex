defmodule Ximula.Gatekeeper do
  defmodule Lock do
    @enforce_keys [:key, :pid]
    defstruct [:key, :pid, :value]
  end

  def get(_server \\ __MODULE__, _fun) do
    42
  end

  def lock(server \\ __MODULE__, keys)

  # Careful if not all keys are available, this function can take some time.
  # As it requests one key at the time, and keeps them until all are released again.
  def lock(server, keys) when is_list(keys) do
    Enum.map(keys, &lock(server, &1))
  end

  def lock(server, key) do
    GenServer.call(server, {:lock, key})
  end

  def lock_and_read(server \\ __MODULE__, keys, fun)

  def lock_and_read(server, keys, fun) when is_list(keys) do
    lock(server, keys)
    |> Enum.map(&Map.put(&1, :value, fun.(&1.key)))
  end

  def lock_and_read(server, key, fun) do
    lock(server, key) |> Map.put(:value, fun.(key))
  end

  def update(server \\ __MODULE__, locks, fun)

  def update(server, [%Lock{} | _] = locks, fun) do
    GenServer.call(server, {:update, locks, fun})
  end

  def update(server, %Lock{} = lock, fun) do
    update(server, [lock], fun)
  end

  def release(server \\ __MODULE__, locks)

  def release(server, [%Lock{} | _] = locks) do
    :ok = GenServer.call(server, {:release, locks})
  end

  def release(server, %Lock{} = lock) do
    :ok = GenServer.call(server, {:release, [lock]})
  end
end
