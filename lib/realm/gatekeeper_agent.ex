defmodule Ximula.Gatekeeper.Agent do
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
