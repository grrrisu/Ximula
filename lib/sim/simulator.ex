defmodule Ximula.Simulator do
  @moduledoc """
  Takes a list of entities to run a simulation function on them and
  returns the results grouped by :ok (success) and :exit (failed).
  If the sim function returns `:no_change` the entity will be removed from the results list.

  Add the task supervisor to your supervision tree

  ```
  children = [
    {Task.Supervisor, name: Ximula.Simulator.Task.Supervisor}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
  ```
  """

  def sim(entities, simulation, id_func \\ & &1, supervisor \\ Ximula.Simulator.Task.Supervisor) do
    sim_entities(entities, simulation, supervisor)
    |> Stream.zip(Enum.map(entities, id_func))
    |> Stream.reject(&not_changed(&1))
    |> Enum.reduce(%{ok: [], exit: []}, &group_by_state/2)
  end

  def benchmark(func) do
    before = Time.utc_now()
    result = func.()
    time_diff = Time.diff(Time.utc_now(), before, :microsecond)
    {time_diff, result}
  end

  defp sim_entities(entities, {module, func, args}, supervisor) do
    Task.Supervisor.async_stream_nolink(supervisor, entities, module, func, args)
  end

  defp group_by_state({{state, result}, id}, %{ok: ok, exit: failed}) do
    case state do
      :ok -> %{ok: [result | ok], exit: failed}
      :exit -> %{ok: ok, exit: [{id, result} | failed]}
    end
  end

  defp not_changed({{:ok, :no_change}, _id}), do: true
  defp not_changed(_), do: false
end
