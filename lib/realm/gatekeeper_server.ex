defmodule Ximula.Gatekeeper.Server do
  use GenServer

  alias Ximula.Gatekeeper.Lock

  @default_lock_duration 5_000

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
       lock_duration: opts[:lock_duration] || @default_lock_duration
     }}
  end

  def handle_call({:lock, key}, {pid, _} = from, state) do
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

  def handle_call({:update, locks, fun}, {pid, _}, state) do
    case validate_owner(locks, pid, state.locks) do
      true ->
        result = call_update(locks, fun)
        state = release_multi(locks, state)
        {:reply, result, state}

      false ->
        {:reply, {:error, "locks must be owned by the caller"}, state}
    end
  end

  def handle_call({:release, locks}, {pid, _}, state) do
    case validate_owner(locks, pid, state.locks) do
      true ->
        state = release_multi(locks, state)
        {:reply, :ok, state}

      false ->
        {:reply, {:error, "locks must be owned by the caller"}, state}
    end
  end

  def handle_info({:lock_timeout, key, _pid}, state) do
    {:noreply, release(state, key)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     state.locks
     |> Map.filter(fn {_key, {key_pid, _, _}} -> key_pid == pid end)
     |> Enum.reduce(state, fn {key, _lock}, state -> release(state, key) end)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp grant_lock(key, pid, state) do
    monitor_ref = Process.monitor(pid)
    timeout_ref = Process.send_after(self(), {:lock_timeout, key, pid}, state.lock_duration)
    lock = %Lock{key: key, pid: pid}
    all_locks = Map.put_new(state.locks, lock.key, {pid, monitor_ref, timeout_ref})
    {:reply, lock, %{state | locks: all_locks}}
  end

  defp add_to_waiting_queue(key, {pid, _} = from, state) do
    monitor_ref = Process.monitor(pid)
    waiting_for_key = Map.get(state.waiting, key, [])
    all_waiting = Map.put(state.waiting, key, waiting_for_key ++ [{from, monitor_ref}])
    {:noreply, %{state | waiting: all_waiting}}
  end

  defp validate_owner(locks, pid, all_locks) do
    Enum.all?(locks, fn lock ->
      Map.get(all_locks, lock.key, {nil, nil, nil})
      |> tap(fn {lock_pid, _, _} -> lock_pid == pid end)
    end)
  end

  defp release_multi(locks, state) do
    Enum.reduce(locks, state, &release(&2, &1.key))
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
    lock = waiting_to_lock(next, key, state.lock_duration)
    locks = Map.put(state.locks, key, lock)
    %{state | locks: locks, waiting: next_waiting(key, rest, state.waiting)}
  end

  defp waiting_to_lock(next, key, lock_duration) do
    {{pid, _} = from, monitor_ref} = next
    timeout_ref = Process.send_after(self(), {:lock_timeout, key, pid}, lock_duration)
    GenServer.reply(from, %Lock{pid: pid, key: key})
    {pid, monitor_ref, timeout_ref}
  end

  def next_waiting(key, [], waiting), do: Map.delete(waiting, key)
  def next_waiting(key, rest, waiting), do: Map.put(waiting, key, rest)

  defp call_update([%Lock{} = lock], fun) do
    fun.({lock.key, lock.value})
  end

  defp call_update([%Lock{} | _] = locks, fun) do
    fun.(Enum.map(locks, &{&1.key, &1.value}))
  end
end
