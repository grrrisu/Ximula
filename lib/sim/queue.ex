defmodule Ximula.Sim.Queue do
  @moduledoc """
  define the following attributes
    name: binary,
    func: &Simulation.sim/1 or {Simulation, :sim, [foo: "bar"]}
    interval: in milisecons


  Depending if the Sim.Loop injects addidional args, the function needs 2 args `&Simulation.sim/2`
  """
  defstruct name: nil,
            func: nil,
            interval: 1_000,
            timer: nil,
            task: nil
end
