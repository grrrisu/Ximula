defmodule Ximula.Gatekeeper do
  def get_context(server \\ __MODULE__) do
    GenServer.call(server, :get_context)
  end

  def get(_server \\ __MODULE__, fun) do
    fun.()
  end

  def request_lock(server \\ __MODULE__, keys)

  # Careful if not all keys are available, this function can take some time.
  # As it requests one key at the time, and keeps them until all are released again.
  def request_lock(server, keys) when is_list(keys) do
    Enum.map(keys, &request_lock(server, &1)) |> Enum.uniq() |> List.first()
  end

  def request_lock(server, key) do
    GenServer.call(server, {:request_lock, key})
  end

  def lock(server \\ __MODULE__, keys, fun)

  def lock(server, keys, fun) when is_list(keys) do
    :ok = request_lock(server, keys)
    Enum.map(keys, &fun.(&1))
  end

  def lock(server, key, fun) do
    :ok = request_lock(server, key)
    fun.(key)
  end

  def update_multi(server, data, fun) when is_list(data) do
    GenServer.call(server, {:update, data, fun})
  end

  def update(server \\ __MODULE__, {key, value}, fun) do
    update_multi(server, [{key, value}], fun)
  end

  def release(server \\ __MODULE__, keys)

  def release(server, keys) when is_list(keys) do
    GenServer.call(server, {:release, keys})
  end

  def release(server, key) do
    release(server, [key])
  end
end
