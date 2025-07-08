defmodule Ximula.AccessData2 do
  @moduledoc """
  A simplified concurrent data access module with per-key locking.

  Core principle: Read operations never block, write operations require exclusive access.

  Usage:
    # Non-blocking read
    data = AccessData.get(server, &Map.get(&1, :key))

    # Exclusive write
    {:ok, lock} = AccessData.lock(server, :key)
    old_value = AccessData.read_locked(server, lock, &Map.get(&1, :key))
    :ok = AccessData.update(server, lock, &Map.put(&1, :key, new_value))

    # Or combined lock+read
    {:ok, old_value, lock} = AccessData.lock_and_read(server, :key, &Map.get(&1, :key))
    :ok = AccessData.update(server, lock, &Map.put(&1, :key, new_value))
  """

  use GenServer

  # Lock handle - makes lock ownership explicit
  defmodule Lock do
    @enforce_keys [:key, :pid, :ref, :server]
    defstruct [:key, :pid, :ref, :server]
  end

  # Default timeout for lock acquisition
  @default_timeout 5_000

  ## Public API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Non-blocking read operation"
  def get(server \\ __MODULE__, fun) do
    GenServer.call(server, {:get, fun})
  end

  @doc "Set entire data structure (fails if any locks exist)"
  def set(server \\ __MODULE__, fun) do
    GenServer.call(server, {:set, fun})
  end

  @doc "Acquire exclusive lock for a key"
  def lock(server \\ __MODULE__, key, timeout \\ @default_timeout) do
    GenServer.call(server, {:lock, key, self()}, timeout)
  end

  @doc "Lock and read in one operation"
  def lock_and_read(server \\ __MODULE__, key, fun, timeout \\ @default_timeout) do
    case lock(server, key, timeout) do
      {:ok, lock} -> {:ok, get(server, fun), lock}
      error -> error
    end
  end

  @doc "Read data using an existing lock (for debugging/verification)"
  def read_locked(server \\ __MODULE__, %Lock{} = lock, fun) do
    verify_lock_owner!(lock)
    get(server, fun)
  end

  @doc "Update data using a lock"
  def update(server \\ __MODULE__, %Lock{} = lock, fun) do
    verify_lock_owner!(lock)
    GenServer.call(lock.server, {:update, lock, fun})
  end

  @doc "Release a lock without updating"
  def release(server \\ __MODULE__, %Lock{} = lock) do
    verify_lock_owner!(lock)
    GenServer.call(lock.server, {:release, lock})
  end

  ## GenServer Implementation

  def init(opts) do
    {:ok,
     %{
       data: opts[:data] || %{},
       # key -> {pid, monitor_ref}
       locks: %{},
       # key -> [{from, monitor_ref}] (queue of waiting processes)
       waiting: %{}
     }}
  end

  def handle_call({:get, fun}, _from, state) do
    {:reply, fun.(state.data), state}
  end

  def handle_call({:set, fun}, _from, state) do
    case map_size(state.locks) do
      0 -> {:reply, :ok, %{state | data: fun.(state.data)}}
      _ -> {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:lock, key, pid}, from, state) do
    case Map.get(state.locks, key) do
      nil ->
        # Key is free, grant lock immediately
        monitor_ref = Process.monitor(pid)
        lock = %Lock{key: key, pid: pid, ref: make_ref(), server: self()}

        new_state = %{state | locks: Map.put(state.locks, key, {pid, monitor_ref})}
        {:reply, {:ok, lock}, new_state}

      {^pid, _monitor_ref} ->
        # Same process already has lock
        {:reply, {:error, :already_locked}, state}

      {_other_pid, _monitor_ref} ->
        # Key is locked by another process, add to queue
        monitor_ref = Process.monitor(pid)
        waiting_list = Map.get(state.waiting, key, [])
        new_waiting = Map.put(state.waiting, key, waiting_list ++ [{from, monitor_ref}])

        {:noreply, %{state | waiting: new_waiting}}
    end
  end

  def handle_call({:update, %Lock{key: key, pid: pid, ref: ref}, fun}, {pid, _}, state) do
    case Map.get(state.locks, key) do
      {^pid, monitor_ref} ->
        # Valid lock, update data and release
        Process.demonitor(monitor_ref, [:flush])
        new_data = fun.(state.data)
        new_locks = Map.delete(state.locks, key)

        # Grant lock to next waiter if any
        {new_locks, new_waiting} = grant_to_next_waiter(key, new_data, new_locks, state.waiting)

        new_state = %{state | data: new_data, locks: new_locks, waiting: new_waiting}
        {:reply, :ok, new_state}

      _ ->
        {:reply, {:error, :invalid_lock}, state}
    end
  end

  def handle_call({:release, %Lock{key: key, pid: pid}}, {pid, _}, state) do
    case Map.get(state.locks, key) do
      {^pid, monitor_ref} ->
        # Valid lock, release without updating
        Process.demonitor(monitor_ref, [:flush])
        new_locks = Map.delete(state.locks, key)

        # Grant lock to next waiter if any
        {new_locks, new_waiting} = grant_to_next_waiter(key, state.data, new_locks, state.waiting)

        new_state = %{state | locks: new_locks, waiting: new_waiting}
        {:reply, :ok, new_state}

      _ ->
        {:reply, {:error, :invalid_lock}, state}
    end
  end

  # Handle process crashes
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    # Remove from locks
    {crashed_keys, new_locks} =
      state.locks
      |> Enum.reject(fn
        {_key, {^pid, ^monitor_ref}} -> true
        _ -> false
      end)
      |> Enum.split_with(fn
        {_key, {^pid, ^monitor_ref}} -> true
        _ -> false
      end)

    new_locks = Map.new(new_locks)

    # Remove from waiting queues and grant locks to next waiters
    {new_locks, new_waiting} =
      Enum.reduce(crashed_keys, {new_locks, state.waiting}, fn {key, _}, {locks, waiting} ->
        # Also remove crashed process from waiting queue
        waiting = remove_from_waiting(waiting, key, pid)
        grant_to_next_waiter(key, state.data, locks, waiting)
      end)

    # Remove crashed process from all waiting queues
    new_waiting =
      Enum.reduce(new_waiting, %{}, fn {key, waiters}, acc ->
        cleaned_waiters =
          Enum.reject(waiters, fn {_from, ref} ->
            case Process.read_monitor(ref) do
              {:process, ^pid} ->
                Process.demonitor(ref, [:flush])
                true

              _ ->
                false
            end
          end)

        if Enum.empty?(cleaned_waiters) do
          acc
        else
          Map.put(acc, key, cleaned_waiters)
        end
      end)

    {:noreply, %{state | locks: new_locks, waiting: new_waiting}}
  end

  ## Private Functions

  defp verify_lock_owner!(%Lock{pid: pid}) do
    if self() != pid do
      raise ArgumentError, "Lock can only be used by the process that acquired it"
    end
  end

  defp grant_to_next_waiter(key, data, locks, waiting) do
    case Map.get(waiting, key) do
      nil ->
        {locks, waiting}

      [] ->
        {locks, Map.delete(waiting, key)}

      [{from, monitor_ref} | rest] ->
        # Grant lock to next waiter
        {pid, _} = from
        lock = %Lock{key: key, pid: pid, ref: make_ref(), server: self()}

        # Reply to waiting process
        GenServer.reply(from, {:ok, lock})

        # Update state
        new_locks = Map.put(locks, key, {pid, monitor_ref})

        new_waiting =
          if Enum.empty?(rest) do
            Map.delete(waiting, key)
          else
            Map.put(waiting, key, rest)
          end

        {new_locks, new_waiting}
    end
  end

  defp remove_from_waiting(waiting, key, pid) do
    case Map.get(waiting, key) do
      nil ->
        waiting

      waiters ->
        new_waiters =
          Enum.reject(waiters, fn {from, monitor_ref} ->
            case from do
              {^pid, _} ->
                Process.demonitor(monitor_ref, [:flush])
                true

              _ ->
                false
            end
          end)

        if Enum.empty?(new_waiters) do
          Map.delete(waiting, key)
        else
          Map.put(waiting, key, new_waiters)
        end
    end
  end
end
