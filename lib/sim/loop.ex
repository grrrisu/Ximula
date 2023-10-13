defmodule Ximula.Sim.Loop do
  @moduledoc """
  The simulation loop server, executes each queue in the given interval

  Add the task supervisors (one for the simulator and one for the loop) to your supervision tree

  ```
  children = [
    {Task.Supervisor, name: Ximula.Simulator.Task.Supervisor}
    {Task.Supervisor, name: Ximula.Sim.Loop.Task.Supervisor}
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

  def add_queue(server \\ __MODULE__, %Queue{} = queue) do
    GenServer.cast(server, {:add_queue, queue})
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

  def handle_cast(:clear, state) do
    {:noreply, %{state | running: false, queues: []}}
  end

  def handle_cast({:add_queue, queue}, state) do
    {:noreply, %{state | queues: [queue | state.queues]}}
  end

  def handle_cast(:start_sim, state) do
    {:noreply, %{state | running: true, queues: start_queues(state.queues)}}
  end

  def handle_cast(:stop_sim, state) do
    {:noreply, %{state | running: false, queues: stop_queues(state.queues)}}
  end

  def handle_info({:tick, queue}, %{running: true} = state) do
    {:noreply, %{state | queues: tick(queue, state)}}
  end

  def handle_info({:tick, _}, %{running: false} = state) do
    Logger.warning("tick on stopped sim loop")
    {:noreply, state}
  end

  def handle_info({ref, response}, state) do
    Process.demonitor(ref, [:flush])
    check_time(response)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # reason Timeout (5000 ms) ???
    check_time(ref, reason, state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

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

  def tick(current_queue, state) do
    queues = Enum.reject(state.queues, fn item -> current_queue.name == item.name end)

    queue =
      current_queue
      |> Map.put(:timer, schedule_next_tick(current_queue))
      |> Map.put(:task, execute(current_queue, state.supervisor, state.sim_args))

    [queue | queues]
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
end
