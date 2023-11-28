defmodule Ximula.AccessGrid do
  @moduledoc """
  Keeps updates on an agent in sequence to avoid race conditions by overwriting data,
  while remaining responsive to read operations.

  data = AccessGrid.get!({1,2}, grid) # blocks until an other exclusive client updates the data
  data = AccessGrid.get({1,2}, grid) # never blocks
  :ok = AccessGrid.update({1,2}, data, grid) # releases the lock and will reply to the next client in line with the updated data
  {:error, msg} = AccessGrid.update({1,2}, data, grid) # if between get! and update too much time elapsed (default 5 sec)

  different updates

  list = AccessGrid.get_list!([{0, 0}, {1, 1}], grid)
  # do something with the values

  update_all writes all changes back one by one, allowing others to read in between

  :ok = AccessGrid.update_all([{{0, 0}, 100}, {{1, 1}, 111}], grid)

  update_all is the same as mapping over each update

  Enum.map([{{0, 0}, 100}, {{1, 1}, 111}], fn {position, data} -> AccessGrid.update(position, data, grid) end)

  update:all! writes all changes back at once without any interruption (like a transaction)
  use this if for example two fields depend on each like movements
  :ok = AccessGrid.update_all!([{{0, 0}, 100}, {{1, 1}, 111}], grid)
  # moving a pawn from {0,0} to {1,1}
  :ok = AccessGrid.update_all!([{{0, 0}, %{pawn: nil}}, {{1, 1}, %{pawn: pawn}}], grid)

  NOTE: get! and update must be called within the same process

  Example:
  {:ok, pid} = Agent.start_link(fn -> Grid.create(5, 5, 0) end)

  # normaly the agent will be referenced by name not pid, so that we don't need to monitor the agent
  {:ok, _} = AccessGrid.start_link(agent: pid)

  1..3
  |> Enum.map(fn _n ->
      Task.async(fn ->
        value = AccessGrid.get!({1,2})
        Process.sleep(1_000)
        :ok = AccessGrid.update({1,2}, value + 1)
      end)
    end)
  |> Task.await_many()
  3 = AccessGrid.get()
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

  # depending if some items of the list are occupied, this function is faster or slower
  def get_list!(list, server \\ __MODULE__) when is_list(list) do
    Enum.map(list, &get!(&1, server))
  end

  # func must return a list of [position]
  def filter!(func, server \\ __MODULE__) when is_function(func) do
    get(func, server)
    |> get_list!(server)
  end

  @doc """
  rquires get! to be called first
  """
  def update(position, data, server \\ __MODULE__) when is_tuple(position) do
    GenServer.call(server, {:update_all!, [{position, data}]})
  end

  @doc """
  updates the list one at the time, allowing read actions in between
  list of [{position, data}]
  """
  def update_all(list, server \\ __MODULE__) when is_list(list) do
    list |> Enum.map(fn {position, data} -> update(position, data, server) end)
  end

  @doc """
  updates the list at once, without interruption.
  if the update fails, the locks will be removed, while the original state is kept
  list of [{position, data}]
  """
  def update_all!(list, server \\ __MODULE__) when is_list(list) do
    GenServer.call(server, {:update_all!, list})
  end

  def release(position, server \\ __MODULE__) when is_tuple(position) do
    update(position, get(position, server), server)
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
    handle_get!({x, y}, from, caller, state)
  end

  def handle_call({:update_all!, list}, {pid, _ref}, state) do
    list
    |> Enum.map(fn {{x, y}, new_data} ->
      %{
        valid: true,
        position: {x, y},
        data: new_data,
        caller: Grid.get(state.caller, x, y),
        requests: Grid.get(state.requests, x, y)
      }
    end)
    |> Enum.map_reduce(true, fn %{caller: caller} = item, valid ->
      item = validate_and_demonitor(item, caller, pid)
      {item, valid && item.valid}
    end)
    |> then(fn {list, valid} ->
      Enum.map(list, &set_data(&1, agent: state.agent, valid: valid))
    end)
    |> Enum.map(&set_requests(&1, max_duration: state.max_duration))
    |> Enum.reduce({state, []}, fn %{position: {x, y}} = item, {state, errors} ->
      {merge_update(state, item), set_errors(errors, {x, y}, item.valid)}
    end)
    |> then(fn {state, errors} ->
      update_reply(errors, pid, state)
    end)
  end

  def handle_info({:check_timeout, {x, y}, {pid, _ref}, monitor_ref}, state) do
    caller = Grid.get(state.caller, x, y)
    requests = Grid.get(state.requests, x, y)
    handle_check_timeout({x, y}, pid, monitor_ref, {caller, requests}, state)
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

  defp handle_get!({x, y}, {pid, _} = from, nil, state) do
    monitor_ref = Process.monitor(pid)
    caller = Grid.put(state.caller, x, y, {pid, monitor_ref})
    start_check_timeout({x, y}, from, monitor_ref, state.max_duration)

    {:reply, get_data(state.agent, {x, y}), %{state | caller: caller}}
  end

  defp handle_get!({x, y}, {pid, _}, {pid, _}, state) do
    {:reply, get_data(state.agent, {x, y}), state}
  end

  defp handle_get!({x, y}, {pid, _} = from, _caller, state) do
    monitor_ref = Process.monitor(pid)
    requests = Grid.get(state.requests, x, y)
    requests = Grid.put(state.requests, x, y, requests ++ [{from, monitor_ref, {x, y}}])
    {:noreply, %{state | requests: requests}}
  end

  defp handle_check_timeout({x, y}, pid, monitor_ref, {{pid, monitor_ref}, []}, state) do
    Process.demonitor(monitor_ref, [:flush])
    {:noreply, %{state | caller: Grid.put(state.caller, x, y, nil)}}
  end

  defp handle_check_timeout({x, y}, pid, monitor_ref, {{pid, monitor_ref}, _requests}, state) do
    Process.demonitor(monitor_ref, [:flush])
    {next_caller, requests} = reply_to_next_caller({x, y}, state)
    {:noreply, %{state | caller: Grid.put(state.caller, x, y, next_caller), requests: requests}}
  end

  defp handle_check_timeout(_pos, _pid, _monitor_ref, _caller_requests, state) do
    {:noreply, state}
  end

  defp validate_and_demonitor(item, nil, _pid) do
    %{item | valid: false}
  end

  defp validate_and_demonitor(item, {pid, monitor_ref}, pid) do
    Process.demonitor(monitor_ref, [:flush])
    %{item | caller: nil}
  end

  defp validate_and_demonitor(item, {_other_pid, _}, _caller_pid) do
    %{item | valid: false}
  end

  defp set_data(%{position: position, data: data} = item, agent: agent, valid: true) do
    update_data(agent, position, data)
    item
  end

  defp set_data(%{position: position} = item, agent: agent, valid: false) do
    %{item | data: get_data(agent, position)}
  end

  defp set_requests(%{requests: []} = item, max_duration: _) do
    item
  end

  defp set_requests(%{position: position, data: data, requests: requests} = item,
         max_duration: max_duration
       ) do
    [{{c_pid, _} = next_caller, next_monitor_ref, _position} | remaining] = requests
    :ok = GenServer.reply(next_caller, data)
    start_check_timeout(position, next_caller, next_monitor_ref, max_duration)
    %{item | caller: {c_pid, next_monitor_ref}, requests: remaining}
  end

  defp merge_update(state, %{position: {x, y}} = item) do
    Map.merge(state, %{
      caller: Grid.put(state.caller, x, y, item.caller),
      requests: Grid.put(state.requests, x, y, item.requests)
    })
  end

  defp set_errors(errors, _position, true), do: errors
  defp set_errors(errors, position, false), do: [position | errors]

  defp update_reply([], _pid, state), do: {:reply, :ok, state}

  defp update_reply(errors, pid, state) do
    msg = Enum.map(errors, fn {x, y} -> "{#{x}, #{y}}" end) |> Enum.join(", ")

    msg =
      "request the data first with AccessGrid#get! #{msg} or maybe too much time elapsed since get! was called"

    {:reply, {:error, msg}, state |> remove_caller(pid) |> remove_request(pid)}
  end

  defp remove_caller(state, pid) do
    state.caller
    |> Grid.positions_and_values()
    |> Enum.filter(&caller_eql(&1, pid))
    |> Enum.map(fn {{x, y}, _} ->
      case Grid.get(state.requests, x, y) do
        [] -> {{x, y}, {nil, state.requests}}
        _ -> {{x, y}, reply_to_next_caller({x, y}, state)}
      end
    end)
    |> Enum.reduce(state, fn {{x, y}, {next_caller, requests}}, state ->
      %{state | caller: Grid.put(state.caller, x, y, next_caller), requests: requests}
    end)
  end

  defp caller_eql({_pos, nil}, _pid), do: nil
  defp caller_eql({_pos, {c_pid, _}}, pid), do: c_pid == pid

  defp remove_request(state, pid) do
    state.requests
    |> Grid.positions_and_values()
    |> Enum.filter(fn {_pos, reqs} ->
      Enum.any?(reqs, &request_eql(&1, pid))
    end)
    |> Enum.map(fn {_pos, reqs} ->
      Enum.reject(reqs, &request_eql(&1, pid))
    end)
    |> Enum.reduce(state, &Grid.apply_changes(&2, &1))
  end

  defp request_eql(nil, _pid), do: nil
  defp request_eql({req_pid, _ref, _func}, pid), do: req_pid == pid

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
