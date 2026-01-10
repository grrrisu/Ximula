defmodule Ximula.Gatekeeper do
  @moduledoc """
  A distributed locking system for coordinating access to shared resources.

  The Gatekeeper provides a mechanism for processes to acquire exclusive locks on
  resources identified by keys. This prevents race conditions and ensures safe
  concurrent access to shared data.

  ## Features

  - **Exclusive Locking**: Only one process can hold a lock on a key at a time
  - **Lock Queuing**: Processes waiting for locked resources are queued and served in order
  - **Automatic Timeout**: Locks automatically expire to prevent deadlocks
  - **Process Monitoring**: Locks are automatically released if the holding process crashes
  - **Multi-key Operations**: Support for atomic operations across multiple keys

  ## Basic Usage

      # Start a gatekeeper server
      {:ok, pid} = Ximula.Gatekeeper.Server.start_link()

      # Request a lock and read value
      value = Ximula.Gatekeeper.lock(pid, :my_key, fn key -> read(key) end)

      # do something with the value
      result = calculate(value)

      # Write the value and release the lock when done
      :ok = Ximula.Gatekeeper.update(pid, :my_key, fn {key, _ignore} -> write(key, value) end)

  ## Multi-key Operations

      # Lock multiple keys atomically
      keys = [:key1, :key2, :key3]
      values = Ximula.Gatekeeper.lock(pid, keys, fn key ->
        read(key)
      end)

      resuls = calculate(values)

      # Update multiple keys atomically
      data = [{"key1", "value1"}, {"key2", "value2"}]
      Ximula.Gatekeeper.update_multi(pid, results, fn results, context ->
        # Apply updates atomically
        apply_updates(results, context)
      end)

  ## Configuration

  The server can be configured with:
  - `max_lock_duration`: Maximum time a lock can be held (default: 5 seconds)
  - `context`: Additional data passed to update functions
  - `name`: Process name for the server

  ## Error Handling

  Most functions return `{:error, reason}` tuples when operations fail:
  - Attempting to update without holding the required locks
  - Trying to release locks not owned by the calling process
  - Server timeouts or crashes

  ## Concurrency Model

  The Gatekeeper uses a fair queuing system where processes waiting for locks
  are served in the order they requested them. This prevents starvation and
  ensures predictable behavior under high contention.
  """
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
    keys |> Enum.sort() |> Enum.map(&request_lock(server, &1)) |> Enum.uniq() |> List.first()
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

  def update(server \\ __MODULE__, key, fun) do
    update_multi(server, [{key, :value_ignored}], fun)
  end

  def release(server \\ __MODULE__, keys)

  def release(server, keys) when is_list(keys) do
    GenServer.call(server, {:release, keys})
  end

  def release(server, key) do
    release(server, [key])
  end
end
