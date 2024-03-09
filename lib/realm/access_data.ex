defmodule Ximula.AccessData do
  @moduledoc """
  Keeps updates on an agent in sequence to avoid race conditions by overwriting data,
  while remaining responsive to just read operations.

  data = AccessProxy.lock(key) # blocks until an other client updates the data
  data = AccessProxy.get(&Map.get(&1, key)) # never blocks
  :ok = AccessProxy.update(key, Map.put(&1, key, new_data)) # releases the lock and will reply to the next client in line with the updated data
  {:error, msg} = AccessProxy.update(key, Map.put(&1, key, new_data)) # if between lock and update too much time elapsed (default 5 sec)

  NOTE: lock and update must be called within the same process

  Example:
  {:ok, pid} = AccessData.start_link(data: %{a: 1, b: 2, c: 3})

  [:a, :a, :b, :b, :c, :c]
  |> Enum.map(fn _n ->
      Task.async(fn ->
        value = AccessData.lock(n, &Map.get(&1, n))
        Process.sleep(1_000)
        :ok = AccessData.update(n, value + 1, &Map.put(&1, &2, &3))
      end)
    end)
  |> Task.await_many()
  %{a: 3, b: 4, c: 5} = AccessData.get(& &1)
  """
  use GenServer

  # milliseconds
  @max_duration 5_000

  @doc """
  opts:
   * name to register
   * data
   * max_duration a caller can exclusivly lock a field
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: opts[:name] || __MODULE__)
  end

  @doc """
  Example
  data = AccessData.get(&Grid.filter(&1, fn _x, _y, v -> v < 10 end), grid)
  """
  def get(server \\ __MODULE__, fun) do
    GenServer.call(server, {:get, fun})
  end

  @doc """
  set the data
  Example
  :ok = AccessData.set(fn grid -> new_grid end)
  {:error, msg} = AccessData.set(fn grid -> new_grid end)
  """
  def set(server \\ __MODULE__, func) do
    GenServer.call(server, {:set, func})
  end

  @doc """
  Example
  data = AccessData.lock_data({1,2}, pid, &Grid.get(&1, {1,2}) end)
  :ok = AccessData.lock_data({1,2}, pid)
  """
  def lock_data(key, server \\ __MODULE__, fun \\ fn _ -> :ok end) do
    GenServer.call(server, {:lock_data, key, fun})
  end

  @doc """
  Example
  data = AccessData.lock({1,2}, pid, &Grid.get(&1, &2) end)
  :ok = AccessData.lock({1,2}, pid)
  """
  def lock(key, server \\ __MODULE__, fun \\ fn _, _ -> :ok end) do
    lock_data(key, server, fn data -> fun.(data, key) end)
  end

  @doc """
  Example
  [data, data] = AccessData.lock([{0, 2}, {1,2}], pid, &Grid.get(&1, &2))
  [:ok, :ok] = AccessData.lock([{0, 2}, {1,2}], pid)
  """
  def lock_list(keys, server \\ __MODULE__, fun \\ fn _, _ -> :ok end) when is_list(keys) do
    Enum.map(keys, &lock(&1, server, fun))
  end

  @doc """
  Example
  :ok = AccessData.lock_list([{0,2}, {1,2}], grid)
  AccessData.update_data([{0,2}, {1,2}], &Grid.apply_changes(&1, [{{0,2}, new_data}, {{1,2}, new_data}]))
  """
  def update_data(keys, server \\ __MODULE__, fun) do
    GenServer.call(server, {:update_data, keys, fun})
  end

  @doc """
  Example
  :ok = AccessData.lock({0,2}, grid)
  AccessData.update({1,2}, new_data, &Grid.put(&1, &2, &3))
  """
  def update(key, data, server \\ __MODULE__, fun) do
    update_list([{key, data}], server, fun)
  end

  @doc """
  Example
  :ok = AccessData.lock_list([{0,2}, {1,2}], grid)
  AccessData.update_list([{{0,2}, new_data}, {{1,2}, new_data}], &Grid.put(&1, &2, &3))
  """
  def update_list(key_values, server \\ __MODULE__, fun) do
    update_data(Enum.map(key_values, &(&1 |> Tuple.to_list() |> List.first())), server, fn data ->
      Enum.reduce(key_values, data, fn {key, value}, data -> fun.(data, key, value) end)
    end)
  end

  def release(key, server \\ __MODULE__)

  def release(keys, server) when is_list(keys) do
    GenServer.call(server, {:update_data, keys, & &1})
  end

  def release(key, server) do
    release([key], server)
  end

  def init(opts) do
    {:ok,
     %{
       data: opts[:data],
       caller: %{},
       requests: %{},
       max_duration: opts[:max_duration] || @max_duration
     }}
  end

  def handle_call({:get, fun}, _from, state) do
    {:reply, fun.(state.data), state}
  end

  def handle_call({:set, func}, _from, %{caller: caller, data: data} = state) do
    case caller |> Map.values() |> Enum.filter(&(!is_nil(&1))) do
      [] -> {:reply, :ok, %{state | data: func.(data)}}
      _ -> {:reply, {:error, "set data failed, object is locked"}, state}
    end
  end

  def handle_call({:lock_data, key, fun}, from, state) do
    handle_lock(
      key,
      fun,
      from,
      Map.get(state.caller, key),
      state
    )
  end

  def handle_call({:update_data, keys, fun}, {pid, _}, state) do
    {errors, caller} =
      Enum.reduce(keys, {[], state.caller}, fn key, {errors, caller} ->
        demonitor_caller(key, pid, caller, errors)
      end)

    data = set_data(state.data, fun, errors)

    {caller, requests} =
      Enum.reduce(keys, {caller, state.requests}, fn key, {caller, requests} ->
        set_requests(key, data, caller, requests, state.max_duration)
      end)

    state = %{state | data: data, caller: caller, requests: requests}
    update_reply(errors, pid, state)
  end

  def handle_info({:check_timeout, key, {pid, _ref}, monitor_ref}, state) do
    caller = Map.get(state.caller, key)
    requests = Map.get(state.requests, key)
    handle_check_timeout(key, pid, monitor_ref, {caller, requests}, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     state
     |> remove_caller(pid)
     |> remove_request(pid)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_lock(key, fun, {pid, _} = from, nil, state) do
    monitor_ref = Process.monitor(pid)
    start_check_timeout(key, from, monitor_ref, state.max_duration)

    {:reply, fun.(state.data), %{state | caller: Map.put(state.caller, key, {pid, monitor_ref})}}
  end

  defp handle_lock(_key, fun, {pid, _}, {pid, _}, state) do
    {:reply, fun.(state.data), state}
  end

  defp handle_lock(key, fun, {pid, _} = from, _caller, state) do
    monitor_ref = Process.monitor(pid)
    requests = Map.get(state.requests, key, [])
    requests = Map.put(state.requests, key, requests ++ [{from, monitor_ref, fun}])
    {:noreply, %{state | requests: requests}}
  end

  defp handle_check_timeout(key, pid, monitor_ref, {{pid, monitor_ref}, []}, state) do
    Process.demonitor(monitor_ref, [:flush])
    {:noreply, %{state | caller: Map.put(state.caller, key, nil)}}
  end

  defp handle_check_timeout(key, pid, monitor_ref, {{pid, monitor_ref}, requests}, state) do
    Process.demonitor(monitor_ref, [:flush])
    {next_caller, requests} = reply_to_next_caller(key, state.data, requests, state.max_duration)

    {:noreply,
     %{
       state
       | caller: Map.put(state.caller, key, next_caller),
         requests: Map.put(state.requests, key, requests)
     }}
  end

  defp handle_check_timeout(_key, _pid, _monitor_ref, _caller_requests, state) do
    {:noreply, state}
  end

  defp start_check_timeout(key, current_caller, monitor_ref, max_duration) do
    Process.send_after(
      self(),
      {:check_timeout, key, current_caller, monitor_ref},
      max_duration
    )
  end

  defp demonitor_caller(key, pid, caller, errors) do
    case Map.get(caller, key) do
      nil ->
        {[key | errors], caller}

      {c_pid, monitor_ref} when pid == c_pid ->
        Process.demonitor(monitor_ref, [:flush])
        {errors, Map.put(caller, key, nil)}

      {_other_pid, _} ->
        {[key | errors], caller}
    end
  end

  defp update_reply([], _pid, state), do: {:reply, :ok, state}

  defp update_reply(errors, pid, state) do
    msg = Enum.map_join(errors, ", ", fn {x, y} -> "{#{x}, #{y}}" end)

    msg =
      "request the data first with AccessGrid#lock #{msg} or maybe too much time elapsed since lock was called"

    {:reply, {:error, msg}, state |> remove_caller(pid) |> remove_request(pid)}
  end

  defp set_requests(key, data, caller, requests, max_duration) do
    req = Map.get(requests, key)

    if req && Enum.any?(req) do
      {c, r} = reply_to_next_caller(key, data, req, max_duration)
      {Map.put(caller, key, c), Map.put(requests, key, r)}
    else
      {caller, requests}
    end
  end

  defp set_data(data, fun, []), do: fun.(data)

  defp set_data(data, _fun, _errors), do: data

  defp reply_to_next_caller(key, data, requests, max_duration) do
    [{{pid, _ref} = next_caller, monitor_ref, fun} | remaining] = requests
    :ok = GenServer.reply(next_caller, fun.(data))
    start_check_timeout(key, next_caller, monitor_ref, max_duration)
    {{pid, monitor_ref}, remaining}
  end

  defp remove_caller(state, pid) do
    state.caller
    |> Enum.filter(&caller_eql(&1, pid))
    |> Enum.map(fn {key, _} ->
      case Map.get(state.requests, key) do
        nil -> {key, {nil, []}}
        [] -> {key, {nil, []}}
        req -> {key, reply_to_next_caller(key, state.data, req, state.max_duration)}
      end
    end)
    |> Enum.reduce(state, fn {key, {next_caller, requests}}, state ->
      %{
        state
        | caller: Map.put(state.caller, key, next_caller),
          requests: Map.put(state.requests, key, requests)
      }
    end)
  end

  defp caller_eql({_key, nil}, _pid), do: nil
  defp caller_eql({_key, {c_pid, _}}, pid), do: c_pid == pid

  defp remove_request(state, pid) do
    state.requests
    |> Enum.filter(fn {_key, reqs} ->
      Enum.any?(reqs, &request_eql(&1, pid))
    end)
    |> Enum.map(fn {key, reqs} ->
      {key, Enum.reject(reqs, &request_eql(&1, pid))}
    end)
    |> Enum.reduce(state, fn {key, requests}, state ->
      %{state | requests: Map.put(state.requests, key, requests)}
    end)
  end

  defp request_eql(nil, _pid), do: nil
  defp request_eql({req_pid, _ref, _func}, pid), do: req_pid == pid
end
