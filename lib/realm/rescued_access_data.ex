defmodule Ximula.AccessData4 do
  @moduledoc """
  A simplified concurrent data access module with per-key locking and timeout protection.

  Core principle: Read operations never block, write operations require exclusive access.
  Locks are automatically released after a timeout to prevent indefinite blocking.

  Usage:
    # Non-blocking read
    data = AccessData.get(server, &Map.get(&1, :key))

    # Exclusive write with timeout protection
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
    @enforce_keys [:key, :pid, :ref]
    defstruct [:key, :pid, :ref]
  end

  # Default timeout for lock acquisition and lock duration
  @default_timeout 5_000
  @default_lock_duration 5_000

  ## Public API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Non-blocking read operation - WARNING: Not coordinated with locks!"
  def unsafe_get(server \\ __MODULE__, fun) do
    GenServer.call(server, {:get, fun})
  end

  @doc "Set entire data structure (fails if any locks exist) - Rarely needed"
  def unsafe_set(server \\ __MODULE__, fun) do
    GenServer.call(server, {:set, fun})
  end

  @doc "Get current data snapshot - use with caution, data may be stale immediately"
  def peek(server \\ __MODULE__) do
    GenServer.call(server, {:get, & &1})
  end

  @doc "Lock multiple keys and read - ensures consistent snapshot"
  def lock_and_read_multi(server \\ __MODULE__, keys, fun, timeout \\ @default_timeout)
      when is_list(keys) do
    case lock_multi(server, keys, timeout) do
      {:ok, locks} ->
        case unsafe_get(server, fun) do
          {:error, _} = error ->
            # If get fails, release all locks
            Enum.each(locks, &release(server, &1))
            error

          result ->
            {:ok, result, locks}
        end

      error ->
        error
    end
  end

  @doc "Lock multiple keys atomically"
  def lock_multi(server \\ __MODULE__, keys, timeout \\ @default_timeout) when is_list(keys) do
    GenServer.call(server, {:lock_multi, keys}, timeout)
  end

  @doc "Update using multiple locks"
  def update_multi(server \\ __MODULE__, locks, fun) when is_list(locks) do
    # Verify all locks belong to current process
    Enum.each(locks, &verify_lock_owner!/1)
    GenServer.call(server, {:update_multi, locks, fun})
  end

  @doc "Release multiple locks"
  def release_multi(server \\ __MODULE__, locks) when is_list(locks) do
    Enum.each(locks, &verify_lock_owner!/1)
    GenServer.call(server, {:release_multi, locks})
  end

  @doc "Acquire exclusive lock for a key"
  def lock(server \\ __MODULE__, key, timeout \\ @default_timeout) do
    GenServer.call(server, {:lock, key}, timeout)
  end

  @doc "Lock and read in one operation"
  def lock_and_read(server \\ __MODULE__, key, fun, timeout \\ @default_timeout) do
    case lock(server, key, timeout) do
      {:ok, lock} ->
        case unsafe_get(server, fun) do
          {:error, _} = error ->
            # If get fails, release the lock to prevent deadlock
            release(server, lock)
            error

          result ->
            {:ok, result, lock}
        end

      error ->
        error
    end
  end

  @doc "Read data using an existing lock (for debugging/verification)"
  def read_locked(server \\ __MODULE__, %Lock{} = lock, fun) do
    verify_lock_owner!(lock)
    unsafe_get(server, fun)
  end

  @doc "Update data using a lock"
  def update(server \\ __MODULE__, %Lock{} = lock, fun) do
    verify_lock_owner!(lock)
    GenServer.call(server, {:update, lock, fun})
  end

  @doc "Release a lock without updating"
  def release(server \\ __MODULE__, %Lock{} = lock) do
    verify_lock_owner!(lock)
    GenServer.call(server, {:release, lock})
  end

  ## GenServer Implementation

  def init(opts) do
    {:ok,
     %{
       data: opts[:data] || %{},
       # key -> {pid, monitor_ref, timeout_ref}
       locks: %{},
       # key -> [{from, monitor_ref}] (queue of waiting processes)
       waiting: %{},
       # Maximum time a lock can be held
       lock_duration: opts[:lock_duration] || @default_lock_duration
     }}
  end

  def handle_call({:get, fun}, _from, state) do
    try do
      {:reply, fun.(state.data), state}
    rescue
      error ->
        {:reply, {:error, {:function_failed, error}}, state}
    catch
      :exit, reason ->
        {:reply, {:error, {:function_exit, reason}}, state}

      value ->
        {:reply, {:error, {:function_throw, value}}, state}
    end
  end

  def handle_call({:set, fun}, _from, state) do
    case map_size(state.locks) do
      0 ->
        try do
          new_data = fun.(state.data)
          {:reply, :ok, %{state | data: new_data}}
        rescue
          error ->
            {:reply, {:error, {:function_failed, error}}, state}
        catch
          :exit, reason ->
            {:reply, {:error, {:function_exit, reason}}, state}

          value ->
            {:reply, {:error, {:function_throw, value}}, state}
        end

      _ ->
        {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:lock, key}, {pid, _} = from, state) do
    case Map.get(state.locks, key) do
      nil ->
        # Key is free, grant lock immediately
        monitor_ref = Process.monitor(pid)
        lock = %Lock{key: key, pid: pid, ref: make_ref()}

        # Start timeout for this lock
        timeout_ref = Process.send_after(self(), {:lock_timeout, key, pid}, state.lock_duration)

        new_state = %{state | locks: Map.put(state.locks, key, {pid, monitor_ref, timeout_ref})}
        {:reply, {:ok, lock}, new_state}

      {^pid, _monitor_ref, _timeout_ref} ->
        # Same process already has lock
        {:reply, {:error, :already_locked}, state}

      {_other_pid, _monitor_ref, _timeout_ref} ->
        # Key is locked by another process, add to queue
        monitor_ref = Process.monitor(pid)
        waiting_list = Map.get(state.waiting, key, [])
        new_waiting = Map.put(state.waiting, key, waiting_list ++ [{from, monitor_ref}])

        {:noreply, %{state | waiting: new_waiting}}
    end
  end

  def handle_call({:update, %Lock{key: key, pid: pid}, fun}, {pid, _}, state) do
    case Map.get(state.locks, key) do
      {^pid, monitor_ref, timeout_ref} ->
        # Valid lock, try to update data
        try do
          new_data = fun.(state.data)

          # Success - clean up and release lock
          Process.demonitor(monitor_ref, [:flush])
          Process.cancel_timer(timeout_ref)

          new_locks = Map.delete(state.locks, key)

          # Grant lock to next waiter if any
          {new_locks, new_waiting} =
            grant_to_next_waiter(key, new_locks, state.waiting, state.lock_duration)

          new_state = %{state | data: new_data, locks: new_locks, waiting: new_waiting}
          {:reply, :ok, new_state}
        rescue
          error ->
            # Function failed - still release the lock to prevent deadlock
            Process.demonitor(monitor_ref, [:flush])
            Process.cancel_timer(timeout_ref)

            new_locks = Map.delete(state.locks, key)

            {new_locks, new_waiting} =
              grant_to_next_waiter(key, new_locks, state.waiting, state.lock_duration)

            new_state = %{state | locks: new_locks, waiting: new_waiting}
            {:reply, {:error, {:function_failed, error}}, new_state}
        catch
          :exit, reason ->
            # Function exited - still release the lock
            Process.demonitor(monitor_ref, [:flush])
            Process.cancel_timer(timeout_ref)

            new_locks = Map.delete(state.locks, key)

            {new_locks, new_waiting} =
              grant_to_next_waiter(key, new_locks, state.waiting, state.lock_duration)

            new_state = %{state | locks: new_locks, waiting: new_waiting}
            {:reply, {:error, {:function_exit, reason}}, new_state}

          value ->
            # Function threw - still release the lock
            Process.demonitor(monitor_ref, [:flush])
            Process.cancel_timer(timeout_ref)

            new_locks = Map.delete(state.locks, key)

            {new_locks, new_waiting} =
              grant_to_next_waiter(key, new_locks, state.waiting, state.lock_duration)

            new_state = %{state | locks: new_locks, waiting: new_waiting}
            {:reply, {:error, {:function_throw, value}}, new_state}
        end

      _ ->
        {:reply, {:error, :invalid_lock}, state}
    end
  end

  def handle_call({:lock_multi, keys}, {pid, _}, state) do
    # Check if any keys are already locked by other processes
    conflicts =
      Enum.filter(keys, fn key ->
        case Map.get(state.locks, key) do
          # Same process already has lock
          {^pid, _, _} -> false
          # Locked by different process
          {_, _, _} -> true
          # Free
          nil -> false
        end
      end)

    case conflicts do
      [] ->
        # All keys are free or owned by same process, grant all locks
        {new_locks, locks_granted} =
          Enum.reduce(keys, {state.locks, []}, fn key, {locks, granted} ->
            case Map.get(locks, key) do
              {^pid, monitor_ref, timeout_ref} ->
                # Already locked by same process, reuse existing lock
                lock = %Lock{key: key, pid: pid, ref: make_ref()}
                {locks, [lock | granted]}

              nil ->
                # Free key, create new lock
                monitor_ref = Process.monitor(pid)

                timeout_ref =
                  Process.send_after(self(), {:lock_timeout, key, pid}, state.lock_duration)

                lock = %Lock{key: key, pid: pid, ref: make_ref()}
                {Map.put(locks, key, {pid, monitor_ref, timeout_ref}), [lock | granted]}
            end
          end)

        {:reply, {:ok, Enum.reverse(locks_granted)}, %{state | locks: new_locks}}

      _conflicts ->
        # Some keys are locked, add to waiting queue for first conflicted key
        # For simplicity, we don't support multi-key waiting - fail fast
        {:reply, {:error, {:keys_locked, conflicts}}, state}
    end
  end

  def handle_call({:update_multi, locks, fun}, {pid, _}, state) do
    # Verify all locks are valid and owned by calling process
    keys = Enum.map(locks, & &1.key)

    validation_result =
      Enum.reduce_while(keys, :ok, fn key, acc ->
        case Map.get(state.locks, key) do
          {^pid, _, _} -> {:cont, acc}
          _ -> {:halt, {:error, {:invalid_lock, key}}}
        end
      end)

    case validation_result do
      :ok ->
        # All locks valid, try to update
        try do
          new_data = fun.(state.data)

          # Success - clean up and release all locks
          {new_locks, new_waiting} =
            Enum.reduce(keys, {state.locks, state.waiting}, fn key, {locks, waiting} ->
              case Map.get(locks, key) do
                {^pid, monitor_ref, timeout_ref} ->
                  Process.demonitor(monitor_ref, [:flush])
                  Process.cancel_timer(timeout_ref)

                  locks_without_key = Map.delete(locks, key)

                  {updated_locks, updated_waiting} =
                    grant_to_next_waiter(key, locks_without_key, waiting, state.lock_duration)

                  {updated_locks, updated_waiting}

                _ ->
                  {locks, waiting}
              end
            end)

          new_state = %{state | data: new_data, locks: new_locks, waiting: new_waiting}
          {:reply, :ok, new_state}
        rescue
          error ->
            # Function failed - still release all locks
            {new_locks, new_waiting} = release_locks_for_pid(keys, pid, state)
            new_state = %{state | locks: new_locks, waiting: new_waiting}
            {:reply, {:error, {:function_failed, error}}, new_state}
        catch
          :exit, reason ->
            {new_locks, new_waiting} = release_locks_for_pid(keys, pid, state)
            new_state = %{state | locks: new_locks, waiting: new_waiting}
            {:reply, {:error, {:function_exit, reason}}, new_state}

          value ->
            {new_locks, new_waiting} = release_locks_for_pid(keys, pid, state)
            new_state = %{state | locks: new_locks, waiting: new_waiting}
            {:reply, {:error, {:function_throw, value}}, new_state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:release_multi, locks}, {pid, _}, state) do
    keys = Enum.map(locks, & &1.key)

    # Verify all locks are valid
    validation_result =
      Enum.reduce_while(keys, :ok, fn key, acc ->
        case Map.get(state.locks, key) do
          {^pid, _, _} -> {:cont, acc}
          _ -> {:halt, {:error, {:invalid_lock, key}}}
        end
      end)

    case validation_result do
      :ok ->
        {new_locks, new_waiting} = release_locks_for_pid(keys, pid, state)
        {:reply, :ok, %{state | locks: new_locks, waiting: new_waiting}}

      error ->
        {:reply, error, state}
    end
  end

  # Handle lock timeout
  def handle_info({:lock_timeout, key, pid}, state) do
    case Map.get(state.locks, key) do
      {^pid, monitor_ref, _timeout_ref} ->
        # Lock timed out, force release
        Process.demonitor(monitor_ref, [:flush])
        new_locks = Map.delete(state.locks, key)

        # Grant lock to next waiter if any
        {new_locks, new_waiting} =
          grant_to_next_waiter(key, new_locks, state.waiting, state.lock_duration)

        {:noreply, %{state | locks: new_locks, waiting: new_waiting}}

      _ ->
        # Lock already released or changed, ignore
        {:noreply, state}
    end
  end

  # Handle process crashes
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    # Remove from locks
    {crashed_keys, remaining_locks} =
      state.locks
      |> Enum.split_with(fn
        {_key, {^pid, ^monitor_ref, _timeout_ref}} -> true
        _ -> false
      end)

    # Cancel timeouts for crashed locks
    Enum.each(crashed_keys, fn {_key, {_pid, _monitor_ref, timeout_ref}} ->
      Process.cancel_timer(timeout_ref)
    end)

    new_locks = Map.new(remaining_locks)

    # Remove from waiting queues and grant locks to next waiters
    {new_locks, new_waiting} =
      Enum.reduce(crashed_keys, {new_locks, state.waiting}, fn {key, _}, {locks, waiting} ->
        # Also remove crashed process from waiting queue
        waiting = remove_from_waiting(waiting, key, pid)
        grant_to_next_waiter(key, locks, waiting, state.lock_duration)
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

  def handle_call({:release, %Lock{key: key, pid: pid}}, {pid, _}, state) do
    case Map.get(state.locks, key) do
      {^pid, monitor_ref, timeout_ref} ->
        # Valid lock, release without updating
        Process.demonitor(monitor_ref, [:flush])
        Process.cancel_timer(timeout_ref)

        new_locks = Map.delete(state.locks, key)

        # Grant lock to next waiter if any
        {new_locks, new_waiting} =
          grant_to_next_waiter(key, new_locks, state.waiting, state.lock_duration)

        new_state = %{state | locks: new_locks, waiting: new_waiting}
        {:reply, :ok, new_state}

      _ ->
        {:reply, {:error, :invalid_lock}, state}
    end
  end

  ## Private Functions

  defp release_locks_for_pid(keys, pid, state) do
    Enum.reduce(keys, {state.locks, state.waiting}, fn key, {locks, waiting} ->
      case Map.get(locks, key) do
        {^pid, monitor_ref, timeout_ref} ->
          Process.demonitor(monitor_ref, [:flush])
          Process.cancel_timer(timeout_ref)

          locks_without_key = Map.delete(locks, key)
          grant_to_next_waiter(key, locks_without_key, waiting, state.lock_duration)

        _ ->
          {locks, waiting}
      end
    end)
  end

  defp verify_lock_owner!(%Lock{pid: pid}) do
    if self() != pid do
      raise ArgumentError, "Lock can only be used by the process that acquired it"
    end
  end

  defp grant_to_next_waiter(key, locks, waiting, lock_duration) do
    case Map.get(waiting, key) do
      nil ->
        {locks, waiting}

      [] ->
        {locks, Map.delete(waiting, key)}

      [{from, monitor_ref} | rest] ->
        # Grant lock to next waiter
        {pid, _} = from
        lock = %Lock{key: key, pid: pid, ref: make_ref()}

        # Start timeout for new lock
        timeout_ref = Process.send_after(self(), {:lock_timeout, key, pid}, lock_duration)

        # Reply to waiting process
        GenServer.reply(from, {:ok, lock})

        # Update state
        new_locks = Map.put(locks, key, {pid, monitor_ref, timeout_ref})

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
