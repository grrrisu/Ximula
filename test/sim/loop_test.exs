defmodule Ximula.Sim.LoopTest do
  use ExUnit.Case

  alias Ximula.Sim.Loop
  alias Ximula.Sim.LoopTest
  alias Ximula.Sim.Queue

  def sim(_queue, dest: test_case), do: send(test_case, :success)

  def too_long(_queue, dest: test_case) do
    Process.sleep(10)
    send(test_case, :success)
  end

  setup do
    simulator_tasks = start_supervised!({Task.Supervisor, name: Simulator.Task.Supervisor})
    loop_tasks = start_supervised!({Task.Supervisor, name: Sim.Loop.Task.Supervisor})
    loop = start_supervised!({Loop, [supervisor: loop_tasks]})
    %{simulator_tasks: simulator_tasks, loop_tasks: loop_tasks, loop: loop}
  end

  test "runs queue", %{loop: loop} do
    queue = %Queue{name: "test", func: {LoopTest, :sim, [dest: self()]}, interval: 5}
    Loop.clear(loop)
    Loop.prepare(loop, queue)
    Loop.start_sim(loop)
    Process.sleep(10)
    Loop.stop_sim(loop)
    assert_received(:success)
  end

  # test "handles timeout", %{loop: loop} do
  #   queue = %Queue{name: "test", func: {LoopTest, :too_long, [dest: self()]}, interval: 5}
  #   Loop.clear(loop)
  #   Loop.prepare(loop, queue)
  #   Loop.start_sim(loop)
  #   Process.sleep(50)
  #   Loop.stop_sim(loop)
  #   assert_received(:success)
  # end
end
