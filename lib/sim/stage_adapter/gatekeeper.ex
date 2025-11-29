defmodule Ximula.Sim.StageAdapter.Gatekeeper do
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper

  @moduledoc """
  Executes a stage with entity locking for coordinated updates.

  Used when entities need to interact or when multiple entities must be
  updated atomically. Integrates with `Ximula.Gatekeeper` for safe
  concurrent access.

  ## Adapter Protocol

  Implements two functions:

  - `get_data/1` - Locks entities and reads their current state
  - `reduce_data/2` - Applies changes atomically via `Gatekeeper.update_multi/3`

  ## Locking Strategy

  1. Stage starts → acquire locks on all keys
  2. Read current state for locked entities
  3. Process in parallel (each entity runs steps)
  4. Collect results
  5. Apply all changes atomically via `update_multi/3`
  6. Release locks

  ## When to Use

  - Cross-entity operations (trade, combat, migration)
  - Coordinated updates that must be atomic
  - Preventing race conditions in concurrent access
  - Entities that reference each other

  ## When NOT to Use

  - Independent entities → use `Grid` (better performance)
  - Single entity → use `Single`
  - If locking overhead exceeds benefit

  ## Required Options

  - `:gatekeeper` - Gatekeeper process/name
  - `:read_fun` - Function to read entity: `(state, key) -> entity`
  - `:write_fun` - Function to write entity: `(state, {key, entity}) -> state`

  ## Performance Considerations

  - Locking has overhead (coordinate only when necessary)
  - All locks acquired upfront (no deadlocks)
  - Parallel processing within locked set
  - Use fine-grained keys to minimize contention
  """

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
