defmodule Ximula.Sim.Queue do
  @moduledoc """
  define the following attributes
    name: binary,
    func: &Simulation.sim/1 or {Simulation, :sim, [foo: "bar"]}
    interval: in milisecons


  Depending if the Sim.Loop injects addidional args, the function needs 2 args `&Simulation.sim/2`
  """
  alias Ximula.Sim.{Pipeline, Queue}

  defstruct name: nil,
            func: nil,
            interval: 1_000,
            timer: nil,
            task: nil

  def add_pipeline(%Queue{} = queue, %{} = pipeline, data) do
    %{queue | func: {Pipeline, :execute, [pipeline, data]}}
  end

  def execute(%Queue{func: func} = queue, []) when is_function(func) do
    queue.func.()
  end

  def execute(%Queue{func: func} = queue, global_args) when is_function(func) do
    queue.func.(global_args)
  end

  def execute(%Queue{func: {module, sim_func, queue_args}}, global_args) do
    args = Keyword.merge(global_args, queue_args)
    apply(module, sim_func, args)
  end
end
