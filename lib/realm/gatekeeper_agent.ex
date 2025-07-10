defmodule Ximula.Gatekeeper.Agent do
  alias Ximula.Gatekeeper.Server
  alias Ximula.Gatekeeper

  def start_link(opts \\ []) do
    Server.start_link(Keyword.merge(opts, name: opts[:name]))
  end

  def get(_server \\ __MODULE__, agent, fun) do
    Agent.get(agent, fun)
  end

  def lock(server \\ __MODULE__, keys) do
    Gatekeeper.lock(server, keys)
  end

  # Ximula.Gatekeeper.Agent.lock_and_read(agent, :a, &Map.get(&1, &2))
  def lock_and_read(server \\ __MODULE__, agent, keys, fun) do
    Gatekeeper.lock_and_read(server, keys, fn key -> Agent.get(agent, &fun.(&1, key)) end)
  end

  # Ximula.Gatekeeper.Agent.update(agent, :a, &Map.update(&1, &2, &3))
  def update(server \\ __MODULE__, agent, locks, fun) do
    Gatekeeper.update(server, locks, fn key_values ->
      Agent.update(agent, &fun.(&1, key_values))
    end)
  end

  def release(server \\ __MODULE__, locks) do
    :ok = Gatekeeper.release(server, locks)
  end
end
