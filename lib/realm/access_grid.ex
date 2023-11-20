defmodule Ximula.AccessGrid do
  @moduledoc """
  Keeps updates on an agent in sequence to avoid race conditions by overwriting data,
  while remaining responsive to just read operations.

  data = AccessProxy.get!() # blocks until an other exclusive client updates the data
  data = AccessProxy.get() # never blocks
  :ok = AccessProxy.update(data) # releases the lock and will reply to the next client in line with the updated data
  {:error, msg} = AccessProxy.update(data) # if between get! and update too much time elapsed (default 5 sec)

  Example:
  {:ok, pid} = Agent.start_link(fn -> 42 end)

  # normaly the agent will be referenced by name not pid, so that we don't need to monitor the agent
  {:ok, _} = AccessProxy.start_link(agent: pid)

  1..3
  |> Enum.map(fn _n ->
      Task.async(fn ->
        value = AccessProxy.get!()
        Process.sleep(1_000)
        :ok = AccessProxy.update(value + 1)
      end)
    end)
  |> Task.await_many()
  45 = AccessProxy.get()
  """

  use GenServer

  alias Ximula.Grid

  # milliseconds
  @max_duration 5_000

  @doc """
  opts:
   * name to register
   * agent holding the grid
   * max_duration a caller can exclusivly lock a field
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: opts[:name] || __MODULE__)
  end

  def get_all(server \\ __MODULE__) do
    GenServer.call(server, :get_all)
  end

  def get(field, server \\ __MODULE__)

  def get(func, server) when is_function(func) do
    GenServer.call(server, {:get, func})
  end

  def get(position, server) when is_tuple(position) do
    GenServer.call(server, {:get, position})
  end

  @doc """
  exclusive get, needed to update a field
  """
  def get!(position, server \\ __MODULE__) when is_tuple(position) do
    GenServer.call(server, {:get!, position})
  end

  @doc """
  needs previously called get!
  """
  def update(position, data, server \\ __MODULE__) when is_tuple(position) do
    GenServer.call(server, {:update, position, data})
  end

  def release(position, server \\ __MODULE__) when is_tuple(position) do
    GenServer.call(server, {:update, & &1})
  end

  def init(opts) do
    width = Agent.get(opts[:agent], & &1) |> Grid.width()
    height = Agent.get(opts[:agent], & &1) |> Grid.height()

    {:ok,
     %{
       caller: Grid.create(width, height),
       agent: opts[:agent],
       requests: Grid.create(width, height, []),
       max_duration: opts[:max_duration] || @max_duration
     }}
  end

  def handle_call(:get_all, _from, state) do
    {:reply, get_data(state.agent, & &1), state}
  end

  def handle_call({:get, func}, _from, state) when is_function(func) do
    {:reply, get_data(state.agent, func), state}
  end

  def handle_call({:get, {x, y}}, _from, state) do
    {:reply, get_data(state.agent, &Grid.get(&1, x, y)), state}
  end

  def handle_call({:get!, {x, y}}, from, state) do
    caller = Grid.get(state.caller, x, y)
    reply_to_get!({x, y}, from, caller, state)
  end

  def handle_call({:update, {x, y}, data}, from, state) do
    caller = Grid.get(state.caller, x, y)
    requests = Grid.get(state.requests, x, y)
    reply_to_update({x, y, data}, from, {caller, requests}, state)
  end

  def handle_info({:check_timeout, {x, y}, {pid, _ref}, monitor_ref}, state) do
    caller = Grid.get(state.caller, x, y)
    requests = Grid.get(state.requests, x, y)
    reply_to_check_timeout({x, y}, pid, monitor_ref, {caller, requests}, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{caller: {pid, _}} = state) do
    {:noreply,
     state
     |> remove_caller(pid)
     |> remove_request(pid)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp reply_to_get!({x, y}, {pid, _} = from, nil, state) do
    monitor_ref = Process.monitor(pid)
    caller = Grid.put(state.caller, x, y, {pid, monitor_ref})
    start_check_timeout({x, y}, from, monitor_ref, state.max_duration)

    {:reply, get_data(state.agent, {x, y}), %{state | caller: caller}}
  end

  defp reply_to_get!({x, y}, {pid, _}, {pid, _}, state) do
    {:reply, get_data(state.agent, {x, y}), state}
  end

  defp reply_to_get!({x, y}, {pid, _} = from, _caller, state) do
    monitor_ref = Process.monitor(pid)
    requests = Grid.get(state.requests, x, y)
    requests = Grid.put(state.requests, x, y, requests ++ [{from, monitor_ref, {x, y}}])
    {:noreply, %{state | requests: requests}}
  end

  defp reply_to_update({x, y, data}, {pid, _}, {{pid, monitor_ref}, []}, state) do
    update_data(state.agent, {x, y}, data)
    Process.demonitor(monitor_ref, [:flush])
    {:reply, :ok, %{state | caller: Grid.put(state.caller, x, y, nil)}}
  end

  defp reply_to_update({x, y, data}, {pid, _}, {{pid, monitor_ref}, _requests}, state) do
    update_data(state.agent, {x, y}, data)
    Process.demonitor(monitor_ref, [:flush])
    {next_caller, state} = reply_to_next_caller({x, y}, state)
    {:reply, :ok, %{state | caller: Grid.put(state.caller, x, y, next_caller)}}
  end

  defp reply_to_update({x, y, _data}, _from, {_caller, _requests}, state) do
    {:reply,
     {:error,
      "request the data first with AccessGrid#get!({#{x},#{y}}) or maybe too much time elapsed since get! was called"},
     state}
  end

  defp reply_to_check_timeout({x, y}, pid, monitor_ref, {{pid, monitor_ref}, []}, state) do
    Process.demonitor(monitor_ref, [:flush])
    {:noreply, %{state | caller: Grid.put(state.caller, x, y, nil)}}
  end

  defp reply_to_check_timeout({x, y}, pid, monitor_ref, {{pid, monitor_ref}, _requests}, state) do
    Process.demonitor(monitor_ref, [:flush])
    {next_caller, requests} = reply_to_next_caller({x, y}, state)

    {:noreply,
     %{
       state
       | caller: Grid.put(state.caller, x, y, next_caller),
         requests: Grid.put(state.requests, x, y, requests)
     }}
  end

  defp reply_to_check_timeout(_pos, _pid, _monitor_ref, _caller_requests, state) do
    {:noreply, state}
  end

  defp remove_caller(state, pid) do
    state.caller
    |> Grid.positions_and_values()
    |> Enum.filter(fn {_pos, {c_pid, _}} -> c_pid == pid end)
    |> Enum.map(fn {{x, y}, _} ->
      case Grid.get(state.requests, x, y) do
        [] -> {{x, y}, {nil, []}}
        _ -> {{x, y}, reply_to_next_caller({x, y}, state)}
      end
    end)
    |> Enum.reduce(state, fn {{x, y}, {next_caller, requests}}, state ->
      %{
        state
        | caller: Grid.put(state.caller, x, y, next_caller),
          requests: Grid.put(state.requests, x, y, requests)
      }
    end)
  end

  defp remove_request(state, pid) do
    state.requests
    |> Grid.positions_and_values()
    |> Enum.filter(fn {_pos, reqs} ->
      Enum.any?(reqs, fn {req_pid, _ref, _func} -> req_pid == pid end)
    end)
    |> Enum.map(fn {_pos, reqs} ->
      Enum.reject(reqs, fn {req_pid, _ref, _func} -> req_pid == pid end)
    end)
    |> Enum.reduce(state, &Grid.apply_changes(&2, &1))
  end

  defp get_data(agent, {x, y}) do
    Agent.get(agent, &Grid.get(&1, x, y))
  end

  defp get_data(agent, func) when is_function(func) do
    Agent.get(agent, func)
  end

  defp update_data(agent, {x, y}, data) do
    :ok = Agent.update(agent, &Grid.put(&1, x, y, data))
  end

  defp reply_to_next_caller({x, y}, state) do
    [{{pid, _ref} = next_caller, monitor_ref, get_args} | remaining] =
      Grid.get(state.requests, x, y)

    :ok = GenServer.reply(next_caller, get_data(state.agent, get_args))
    start_check_timeout({x, y}, next_caller, monitor_ref, state.max_duration)
    {{pid, monitor_ref}, Grid.put(state.requests, x, y, remaining)}
  end

  defp start_check_timeout({x, y}, current_caller, monitor_ref, max_duration) do
    Process.send_after(
      self(),
      {:check_timeout, {x, y}, current_caller, monitor_ref},
      max_duration
    )
  end
end
