defmodule Ximula.Gatekeeper.Server do
  @moduledoc """
  GenServer implementation for the Gatekeeper distributed locking system.

  This module provides the core server functionality for managing locks, queues,
  and timeouts. It should typically not be used directly - instead use the
  `Ximula.Gatekeeper` or `Ximula.Gatekeeper.Agent` modules which provide
  higher-level interfaces.

  ## State Structure

  The server maintains the following state:

  - `locks`: Map of `key -> {pid, monitor_ref, timeout_ref}` representing active locks
  - `waiting`: Map of `key -> [{from, monitor_ref}]` representing queued processes
  - `max_lock_duration`: Maximum time a lock can be held before automatic timeout
  - `context`: Additional data available to update functions

  ## Lock Lifecycle

  1. **Request**: Process requests a lock via `handle_call({:request_lock, key}, ...)`
  2. **Grant**: If available, lock is granted immediately with monitoring and timeout
  3. **Queue**: If unavailable, process is added to waiting queue for that key
  4. **Release**: Lock is released via explicit call, timeout, or process crash
  5. **Next**: Next process in queue (if any) is automatically granted the lock

  ## Timeout Handling

  Each lock has an associated timeout that automatically releases it after
  `max_lock_duration` milliseconds. This prevents deadlocks when processes
  crash or hang while holding locks.

  ## Process Monitoring

  The server monitors all processes that hold locks or are waiting for locks.
  If a monitored process crashes, all its locks are automatically released
  and it's removed from all waiting queues.

  ## Configuration Options

  - `max_lock_duration`: Timeout for automatic lock release (default: 5000ms)
  - `context`: Additional data passed to update functions
  - `name`: Process name for registration

  ## Example

      # Start server with custom configuration
      {:ok, pid} = Ximula.Gatekeeper.Server.start_link([
        max_lock_duration: 10_000,
        context: %{database: my_db},
        name: :my_gatekeeper
      ])

  ## Internal Messages

  The server handles several internal messages:
  - `{:lock_timeout, key, pid}`: Automatic lock timeout
  - `{:DOWN, ref, :process, pid, reason}`: Process crash notification
  """
  use GenServer

  @default_max_lock_duration 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def init(opts \\ []) do
    {:ok,
     %{
       # key -> {pid, monitor_ref, timeout_ref}
       locks: %{},
       # key -> [{from, monitor_ref}] (queue of waiting processes)
       waiting: %{},
       # Maximum time a lock can be held
       max_lock_duration: opts[:max_lock_duration] || @default_max_lock_duration,
       # Context
       context: opts[:context] || %{}
     }}
  end

  def handle_call(:get_context, _from, state) do
    {:reply, state.context, state}
  end

  def handle_call({:request_lock, key}, {pid, _} = from, state) do
    case Map.get(state.locks, key) do
      nil ->
        # Key is free, grant lock immediately
        grant_lock(key, pid, state)

      {^pid, _monitor_ref, _timeout_ref} = lock ->
        # Same process already has lock
        {:reply, lock, state}

      {_other_pid, _monitor_ref, _timeout_ref} ->
        # Key is locked by another process, add to queue
        add_to_waiting_queue(key, from, state)
    end
  end

  def handle_call({:update, data, fun}, {pid, _}, state) do
    keys = Enum.map(data, fn {key, _value} -> key end)

    case validate_owner(keys, pid, state.locks) do
      true ->
        result = call_update(data, state.context, fun)
        state = release_multi(keys, state)
        {:reply, result, state}

      false ->
        {:reply, {:error, "locks #{inspect(keys)} must be owned by the caller"},
         remove_caller(state, pid)}
    end
  end

  def handle_call({:release, keys}, {pid, _}, state) do
    case validate_owner(keys, pid, state.locks) do
      true ->
        state = release_multi(keys, state)
        {:reply, :ok, state}

      false ->
        {:reply, {:error, "locks #{inspect(keys)} must be owned by the caller"}, state}
    end
  end

  def handle_info({:lock_timeout, key, _pid}, state) do
    {:noreply, release(state, key)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_caller(state, pid)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp grant_lock(key, pid, state) do
    monitor_ref = Process.monitor(pid)
    timeout_ref = Process.send_after(self(), {:lock_timeout, key, pid}, state.max_lock_duration)
    all_locks = Map.put_new(state.locks, key, {pid, monitor_ref, timeout_ref})
    {:reply, :ok, %{state | locks: all_locks}}
  end

  defp add_to_waiting_queue(key, {pid, _} = from, state) do
    monitor_ref = Process.monitor(pid)
    waiting_for_key = Map.get(state.waiting, key, [])
    all_waiting = Map.put(state.waiting, key, waiting_for_key ++ [{from, monitor_ref}])
    {:noreply, %{state | waiting: all_waiting}}
  end

  defp validate_owner(keys, pid, locks) do
    Enum.all?(keys, fn key ->
      case Map.get(locks, key) do
        {^pid, _, _} -> true
        _ -> false
      end
    end)
  end

  defp release_multi(keys, state) do
    Enum.reduce(keys, state, fn key, state -> release(state, key) end)
  end

  defp release(state, key) do
    {lock, locks} = Map.pop(state.locks, key)
    demonitor(lock)
    state = %{state | locks: locks}

    state.waiting
    |> Map.get(key)
    |> grant_next_in_line(state, key)
  end

  defp demonitor(nil), do: nil

  defp demonitor({_pid, monitor_ref, timeout_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    Process.cancel_timer(timeout_ref)
  end

  defp grant_next_in_line(nil, state, _key), do: state
  defp grant_next_in_line([], state, key), do: %{state | waiting: Map.delete(state.waiting, key)}

  defp grant_next_in_line([next | rest], state, key) do
    lock = waiting_to_lock(next, key, state.max_lock_duration)
    locks = Map.put(state.locks, key, lock)
    %{state | locks: locks, waiting: next_waiting(key, rest, state.waiting)}
  end

  defp waiting_to_lock(next, key, max_lock_duration) do
    {{pid, _} = from, monitor_ref} = next
    timeout_ref = Process.send_after(self(), {:lock_timeout, key, pid}, max_lock_duration)
    GenServer.reply(from, :ok)
    {pid, monitor_ref, timeout_ref}
  end

  def next_waiting(key, [], waiting), do: Map.delete(waiting, key)
  def next_waiting(key, rest, waiting), do: Map.put(waiting, key, rest)

  defp call_update([{key, value}], context, fun) do
    fun.({key, value}, context)
  end

  defp call_update(data, context, fun) when is_list(data) do
    fun.(data, context)
  end

  defp remove_caller(state, pid) do
    state =
      state.locks
      |> Map.filter(fn {_key, {key_pid, _, _}} -> key_pid == pid end)
      |> Enum.reduce(state, fn {key, _lock}, state -> release(state, key) end)

    %{state | waiting: remove_waiting(pid, state.waiting)}
  end

  defp remove_waiting(pid, waiting) do
    waiting
    |> Enum.reduce(%{}, fn {key, queue}, acc ->
      # Filter out entries for the crashed process and demonitor them
      new_queue =
        queue
        |> Enum.reject(fn {{queue_pid, _}, monitor_ref} ->
          demonitor_waiting(queue_pid, pid, monitor_ref)
        end)

      # Only keep the key if there are still processes waiting
      if new_queue != [] do
        Map.put(acc, key, new_queue)
      else
        acc
      end
    end)
  end

  defp demonitor_waiting(pid, pid, monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    true
  end

  defp demonitor_waiting(_queue_pid, _pid, _monitor_ref), do: false
end
