defmodule Ximula.AccessData do
  @moduledoc """

  could this also be achieved with Mutex

  def get_by

  sync def lock

  sync def update

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
  data = AccessData.get_by(&Grid.filter(&1, fn _x, _y, v -> v < 10 end), grid)
  """
  def get_by(server \\ __MODULE__, fun) do
    GenServer.call(server, {:get_by, fun})
  end

  @doc """
  Example
  data = AccessData.lock({1,2}, grid, &Grid.get(&1, &2))
  :ok = AccessData.lock({1,2}, grid)
  """
  def lock(key, server \\ __MODULE__, fun \\ fn _, _ -> :ok end) do
    GenServer.call(server, {:lock, key, fun})
  end

  @doc """
  Example
  [data, data] = AccessData.lock([{0, 2}, {1,2}], grid, &Grid.get(&1, &2))
  [:ok, :ok] = AccessData.lock([{0, 2}, {1,2}], grid)
  """
  def lock_list(keys, server \\ __MODULE__, fun \\ fn _, _ -> :ok end) when is_list(keys) do
    Enum.map(keys, &lock(&1, server, fun))
  end

  @doc """
  Example
  :ok = AccessData.lock([{0,2}, {1,2}], grid)
  AccessData.update([{1,2}], &Grid.update(&1, &2, new_data))
  """
  def update(key, data, server \\ __MODULE__, fun) do
    update_list([{key, data}], server, fun)
  end

  @doc """
  Example
  :ok = AccessData.lock({1,2}, grid)
  AccessData.update({1,2}, &Grid.update(&1, &2, new_data))
  """
  def update_list(keys, server \\ __MODULE__, fun) do
    GenServer.call(server, {:update_list, keys, fun})
  end

  def release(keys, server \\ __MODULE__) do
    GenServer.call(server, {:release, keys})
  end

  @spec init(nil | maybe_improper_list() | map()) ::
          {:ok, %{caller: %{}, data: any(), max_duration: any(), requests: %{}}}
  def init(opts) do
    {:ok,
     %{
       data: opts[:data],
       caller: %{},
       requests: %{},
       max_duration: opts[:max_duration] || @max_duration
     }}
  end

  def handle_call({:get_by, fun}, _from, state) do
    {:reply, fun.(state.data), state}
  end

  def handle_call({:lock, key, fun}, from, state) do
    handle_lock(
      key,
      fun,
      from,
      Map.get(state.caller, key),
      state
    )
  end

  def handle_call({:update_list, list, fun}, {pid, _}, state) do
    {errors, caller} =
      Enum.reduce(list, {[], state.caller}, fn {key, _}, {errors, caller} ->
        demonitor_caller(key, pid, caller, errors)
      end)

    data = set_data(list, state.data, fun, errors)

    {caller, requests} =
      Enum.reduce(list, {caller, state.requests}, fn {key, _}, {caller, requests} ->
        set_requests(key, data, caller, requests, state.max_duration)
      end)

    state = %{state | data: data, caller: caller, requests: requests}
    update_reply(errors, pid, state)
  end

  def handle_call({:release, keys}, {pid, _}, state) do
    {errors, caller} =
      Enum.reduce(keys, {[], state.caller}, fn key, {errors, caller} ->
        demonitor_caller(key, pid, caller, errors)
      end)

    {caller, requests} =
      Enum.reduce(keys, {caller, state.requests}, fn key, {caller, requests} ->
        set_requests(key, state.data, caller, requests, state.max_duration)
      end)

    update_reply(errors, pid, %{state | caller: caller, requests: requests})
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

    {:reply, fun.(state.data, key),
     %{state | caller: Map.put(state.caller, key, {pid, monitor_ref})}}
  end

  defp handle_lock(key, fun, {pid, _}, {pid, _}, state) do
    {:reply, fun.(state.data, key), state}
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
    msg = Enum.map(errors, fn {x, y} -> "{#{x}, #{y}}" end) |> Enum.join(", ")

    msg =
      "request the data first with AccessGrid#get! #{msg} or maybe too much time elapsed since get! was called"

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

  defp set_data(list, data, fun, []) do
    Enum.reduce(list, data, fn {key, value}, data ->
      fun.(data, key, value)
    end)
  end

  defp set_data(_list, data, _fun, _errors), do: data

  defp reply_to_next_caller(key, data, requests, max_duration) do
    [{{pid, _ref} = next_caller, monitor_ref, fun} | remaining] = requests
    :ok = GenServer.reply(next_caller, fun.(data, key))
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
