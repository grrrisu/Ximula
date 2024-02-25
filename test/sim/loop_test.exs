defmodule Ximula.Sim.LoopTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.Loop
  alias Ximula.Sim.LoopTest
  alias Ximula.Sim.Queue

  def one(_queue), do: 1

  def callback(_queue, dest: test_case), do: send(test_case, :success)

  def too_long(_queue, dest: test_case) do
    Process.sleep(10)
    send(test_case, :success)
  end

  describe "" do
    setup do
      %{loop: start_supervised!(Loop)}
    end

    test "add queue", %{loop: loop} do
      assert [] == Loop.get_queues(loop)
      :ok = Loop.add_queue(loop, %Queue{name: "first"})
      assert [queue] = Loop.get_queues(loop)
      assert "first" == queue.name
    end

    test "add multiple queues", %{loop: loop} do
      assert [] == Loop.get_queues(loop)
      :ok = Loop.add_queue(loop, %Queue{name: "first"})
      :ok = Loop.add_queue(loop, %Queue{name: "second"})
      assert 2 == Loop.get_queues(loop) |> Enum.count()
      assert %Queue{name: "second"} = Loop.get_queues(loop) |> Enum.find(&(&1.name == "second"))
    end

    test "replace queue", %{loop: loop} do
      assert [] == Loop.get_queues(loop)
      :ok = Loop.add_queue(loop, %Queue{name: "first", interval: 5})
      :ok = Loop.add_queue(loop, %Queue{name: "first", interval: 10})
      assert 1 == Loop.get_queues(loop) |> Enum.count()
      assert %Queue{name: "first", interval: 10} == Loop.get_queues(loop) |> List.first()
    end
  end

  describe "start and stop" do
    setup do
      simulator_tasks = start_supervised!({Task.Supervisor, name: Simulator.Task.Supervisor})
      loop_tasks = start_supervised!({Task.Supervisor, name: Sim.Loop.Task.Supervisor})
      loop = start_supervised!({Loop, [supervisor: loop_tasks]})
      %{simulator_tasks: simulator_tasks, loop_tasks: loop_tasks, loop: loop}
    end

    @tag ci: :skip
    test "runs queue", %{loop: loop} do
      queue = %Queue{name: "test", func: {LoopTest, :callback, [dest: self()]}, interval: 5}
      Loop.clear(loop)
      Loop.add_queue(loop, queue)
      Loop.start_sim(loop)
      Process.sleep(50)
      Loop.stop_sim(loop)
      assert_received(:success)
    end

    @tag ci: :skip
    test "handles timeout", %{loop: loop} do
      queue = %Queue{name: "test", func: {LoopTest, :too_long, [dest: self()]}, interval: 5}
      Loop.clear(loop)
      Loop.add_queue(loop, queue)
      Loop.start_sim(loop)
      Process.sleep(200)
      Loop.stop_sim(loop)
      assert_received(:success)
    end
  end

  describe "queues" do
    setup do
      %{queues: Enum.map(1..3, &%Queue{name: &1})}
    end

    test "should be started and stopped", %{queues: queues} do
      queues = Loop.start_queues(queues)
      assert Enum.all?(queues, &(&1.timer != nil))
      queues = Loop.stop_queues(queues)
      assert Enum.all?(queues, &(&1.timer == nil))
    end

    test "should execute sim function" do
      loop_tasks = start_supervised!({Task.Supervisor, name: Sim.Loop.Task.Supervisor})
      queue = %Queue{name: "test", func: &LoopTest.one/1}
      %Queue{task: task, timer: timer} = Loop.tick(queue, loop_tasks, [])
      assert task != nil
      assert timer != nil
    end

    test "should skip execution if task is still running" do
      loop_tasks = start_supervised!({Task.Supervisor, name: Sim.Loop.Task.Supervisor})
      queue = %Queue{name: "test", func: &LoopTest.one/1, task: self(), timer: self()}
      %Queue{task: task, timer: timer} = Loop.tick(queue, loop_tasks, [])
      # still the same task
      assert task == self()
      # new timer has been set
      assert timer != self()
    end
  end
end
