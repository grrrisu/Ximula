defmodule Ximula.Sim.Loop do
  @moduledoc """
  The simulation loop server, executes each queue in the given interval

  Add the task supervisors (one for the simulator and one for the loop) to your supervision tree

  ```
  children = [
    {Task.Supervisor, name: Ximula.Simulator.Task.Supervisor},
    {Task.Supervisor, name: Ximula.Sim.Loop.Task.Supervisor},
    {Ximula.Sim.Loop}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
  ```
  """
  use GenServer

  alias Ximula.Sim.Queue
  alias Ximula.Simulator

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def get_queues(server \\ __MODULE__) do
    GenServer.call(server, :get_queues)
  end

  # adds or replaces a queue with the same name
  def add_queue(server \\ __MODULE__, %Queue{} = queue) do
    GenServer.call(server, {:add_queue, queue})
  end

  def clear(server \\ __MODULE__) do
    GenServer.cast(server, :clear)
  end

  def start_sim(server \\ __MODULE__) do
    GenServer.cast(server, :start_sim)
  end

  def stop_sim(server \\ __MODULE__) do
    GenServer.cast(server, :stop_sim)
  end

  def init(opts) do
    {:ok,
     %{
       running: false,
       queues: [],
       supervisor: opts[:supervisor] || Ximula.Sim.Loop.Task.Supervisor,
       sim_args: opts[:sim_args] || []
     }}
  end

  def handle_call(:get_queues, _from, state) do
    {:reply, state.queues, state}
  end

  def handle_call({:add_queue, queue}, _from, state) do
    index = Enum.find_index(state.queues, &(&1.name == queue.name))
    queues = add_queue(state.queues, index, queue, state.running)

    case queues do
      {:error, msg} -> {:reply, {:error, msg}, state}
      queues -> {:reply, :ok, %{state | queues: queues}}
    end
  end

  def handle_cast(:clear, state) do
    {:noreply, %{state | running: false, queues: []}}
  end

  def handle_cast(:start_sim, state) do
    {:noreply, %{state | running: true, queues: start_queues(state.queues)}}
  end

  def handle_cast(:stop_sim, state) do
    {:noreply, %{state | running: false, queues: stop_queues(state.queues)}}
  end

  def handle_info({:tick, queue}, %{running: true} = state) do
    queues =
      find_and_update_queue!(
        state.queues,
        &(&1.name == queue.name),
        &tick(&1, state.supervisor, state.sim_args)
      )

    {:noreply, %{state | queues: queues}}
  end

  def handle_info({:tick, _}, %{running: false} = state) do
    Logger.warning("tick on stopped sim loop")
    {:noreply, state}
  end

  def handle_info({ref, response}, state) do
    Process.demonitor(ref, [:flush])
    check_time(response)
    {:noreply, %{state | queues: reset_queue_task!(state.queues, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    check_time(ref, reason, state)
    {:noreply, %{state | queues: reset_queue_task!(state.queues, ref)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # adding a queue to running system can lead to errors,
  # as the timer and task reference would get lost.
  def add_queue(_queues, _index, _queue, true),
    do: {:error, "do not add a queue to a running loop"}

  def add_queue(queues, nil, queue, false), do: [queue | queues]
  def add_queue(queues, index, queue, false), do: List.replace_at(queues, index, queue)

  def start_queues(queues) do
    Enum.map(queues, fn queue ->
      Map.put(queue, :timer, schedule_next_tick(queue))
    end)
  end

  def stop_queues(queues) do
    Enum.map(queues, fn queue ->
      stop_timer(queue.timer)
      %{queue | timer: nil}
    end)
  end

  def tick(%Queue{task: nil} = queue, supervisor, args) do
    queue
    |> Map.put(:timer, schedule_next_tick(queue))
    |> Map.put(:task, execute(queue, supervisor, args))
  end

  def tick(%Queue{task: _still_running} = queue, _supervisor, _args) do
    Logger.warning("Queue is too slow! Previous task didn't return yet. Skipping this tick!")
    Map.put(queue, :timer, schedule_next_tick(queue))
  end

  def check_time({time, {_results, queue}}) do
    if time < queue.interval * 1000 do
      Logger.info("queue #{queue.name} took #{time} μs")
    else
      Logger.warning(
        "queue #{queue.name} took #{time} μs, but has an interval of #{queue.interval * 1000} μs"
      )
    end
  end

  def check_time(ref, reason, state) do
    queue = Enum.find(state.queues, fn queue -> get_task_ref(queue) == ref end)

    if queue do
      Logger.error("queue #{queue.name} failed! #{Exception.format_exit(reason)}")
    else
      Logger.error("UNKNOWN queue failed! #{Exception.format_exit(reason)}")
    end
  end

  defp get_task_ref(%Queue{task: nil}), do: nil
  defp get_task_ref(%Queue{task: task}), do: task.ref

  defp execute(queue, supervisor, sim_args) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      Simulator.benchmark(fn ->
        {execute_sim_function(queue, sim_args), queue}
      end)
    end)
  end

  defp execute_sim_function(%Queue{func: func} = queue, []) when is_function(func) do
    queue.func.(queue)
  end

  defp execute_sim_function(%Queue{func: func} = queue, global_args) when is_function(func) do
    queue.func.(queue, global_args)
  end

  defp execute_sim_function(%Queue{func: {module, sim_func, queue_args}} = queue, global_args) do
    args = Keyword.merge(global_args, queue_args)
    apply(module, sim_func, [queue, args])
  end

  defp schedule_next_tick(queue) do
    Process.send_after(self(), {:tick, queue}, queue.interval)
  end

  defp stop_timer(nil), do: nil
  defp stop_timer(ref), do: Process.cancel_timer(ref)

  defp find_and_update_queue!(queues, find_func, update_func) do
    case Enum.find_index(queues, &find_func.(&1)) do
      nil -> raise(KeyError, "FATAL: Queue could not be found. Restarting Sim.Loop!")
      index -> List.update_at(queues, index, &update_func.(&1))
    end
  end

  defp reset_queue_task!(queues, ref) do
    find_and_update_queue!(queues, &(get_task_ref(&1) == ref), &Map.put(&1, :task, nil))
  end
end
