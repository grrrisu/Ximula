defmodule Ximula.Gatekeeper.Agent do
  @moduledoc """
  High-level interface for using Gatekeeper with Elixir Agents.

  This module provides a convenient wrapper around the core Gatekeeper functionality
  that integrates seamlessly with Elixir's Agent behavior. It's designed for scenarios
  where you want to safely coordinate access to shared state managed by an Agent.

  ## Setup

  The Agent module expects the Gatekeeper server to be configured with a context
  containing an `:agent` key that points to an Agent process:

      # Create an Agent with initial state
      {:ok, agent} = Agent.start_link(fn -> %{} end)

      # Start Gatekeeper server with Agent in context
      {:ok, gatekeeper} = Ximula.Gatekeeper.Server.start_link([
        context: %{agent: agent}
      ])

  ## Reading Data

  Use `get/2` to read from the Agent without acquiring locks:

      # Read data (non-blocking)
      value = Ximula.Gatekeeper.Agent.get(gatekeeper, fn state ->
        Map.get(state, :my_key)
      end)

  ## Locking and Reading

  Use `lock/3` to acquire a lock and read atomically:

      # Lock a key and read its value
      value = Ximula.Gatekeeper.Agent.lock(gatekeeper, :my_key, fn state, key ->
        Map.get(state, key)
      end)

      # Lock multiple keys
      values = Ximula.Gatekeeper.Agent.lock(gatekeeper, [:key1, :key2], fn state, key ->
        Map.get(state, key)
      end)

  ## Updating Data

  Use `update/3` to modify the Agent state while holding the appropriate lock:

      # First acquire the lock
      :ok = Ximula.Gatekeeper.Agent.request_lock(gatekeeper, :my_key)

      # Then update
      :ok = Ximula.Gatekeeper.Agent.update(gatekeeper, {:my_key, "new_value"}, fn state, {key, value} ->
        Map.put(state, key, value)
      end)

  ## Batch Updates

  Use `update_multi/3` for atomic updates across multiple keys:

      # Lock multiple keys first
      :ok = Ximula.Gatekeeper.Agent.request_lock(gatekeeper, [:key1, :key2])

      # Update multiple keys atomically
      data = [key1: "value1", key2: "value2"]
      :ok = Ximula.Gatekeeper.Agent.update_multi(gatekeeper, data, fn state, updates ->
        Enum.reduce(updates, state, fn {key, value}, acc ->
          Map.put(acc, key, value)
        end)
      end)

  ## Lock Management

  The module provides direct access to lock management:

      # Request locks explicitly
      :ok = Ximula.Gatekeeper.Agent.request_lock(gatekeeper, [:key1, :key2])

      # Release locks when done
      :ok = Ximula.Gatekeeper.Agent.release(gatekeeper, [:key1, :key2])

  ## Error Handling

  Operations return `{:error, reason}` when they fail:
  - Attempting to update without holding the required locks
  - Trying to release locks not owned by the calling process

  ## Thread Safety

  This module ensures thread-safe access to Agent state by coordinating all
  updates through the locking mechanism. Multiple processes can safely read
  and write to the same Agent without race conditions.

  ## Performance Considerations

  - `get/2` operations are non-blocking and don't acquire locks
  - `lock/3` operations are blocking and serialize access per key
  - `update/3` and `update_multi/3` automatically release locks after completion
  - Failed updates automatically clean up locks to prevent deadlocks
  """
  alias Ximula.Gatekeeper.Server
  alias Ximula.Gatekeeper

  def start_link(opts \\ []) do
    Server.start_link(Keyword.merge(opts, name: opts[:name]))
  end

  def get(server \\ __MODULE__, fun) do
    context = Gatekeeper.get_context(server)
    Agent.get(context.agent, fun)
  end

  def request_lock(server \\ __MODULE__, keys) do
    Gatekeeper.request_lock(server, keys)
  end

  # Ximula.Gatekeeper.Agent.lock_and_read(agent, :a, &Map.get(&1, &2))
  def lock(server \\ __MODULE__, keys, fun) do
    context = Gatekeeper.get_context(server)
    Gatekeeper.lock(server, keys, fn key -> Agent.get(context.agent, &fun.(&1, key)) end)
  end

  # Ximula.Gatekeeper.Agent.update(agent, :a, &Map.update(&1, &2, &3))
  def update(server \\ __MODULE__, {key, value}, fun) do
    Gatekeeper.update(server, {key, value}, fn {key, value}, context ->
      Agent.update(context.agent, &fun.(&1, {key, value}))
    end)
  end

  def update_multi(server \\ __MODULE__, data, fun) do
    Gatekeeper.update_multi(server, data, fn data, context ->
      Agent.update(context.agent, &fun.(&1, data))
    end)
  end

  def release(server \\ __MODULE__, locks) do
    Gatekeeper.release(server, locks)
  end
end
