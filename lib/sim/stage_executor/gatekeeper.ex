defmodule Ximula.Sim.StageExecutor.Gatekeeper do
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper

  def get_data(%{data: keys, opts: opts}) do
    Gatekeeper.lock(opts[:gatekeeper], keys, opts[:read_fun])
  end

  def reduce_data({:error, reasons}, _gatekeeper, _fun, _keys), do: {:error, reasons}

  def reduce_data({:ok, results}, %{data: keys, opts: opts}) do
    results = Enum.map(results, fn %{position: position, field: field} -> {position, field} end)

    :ok =
      Gatekeeper.update_multi(opts[:gatekeeper], results, fn data ->
        Enum.reduce(results, data, &opts[:write_fun].(&2, &1))
      end)

    {:ok, keys}
  end
end
