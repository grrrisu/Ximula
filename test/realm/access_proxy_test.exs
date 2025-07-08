defmodule Ximula.AccessProxyTest do
  use ExUnit.Case, async: true

  alias Ximula.AccessProxy

  setup do
    agent = start_supervised!({Agent, fn -> 42 end})
    proxy = start_supervised!({AccessProxy, [agent: agent]})
    supervisor = start_link_supervised!(Task.Supervisor)

    %{agent: agent, proxy: proxy, supervisor: supervisor}
  end

  describe "update" do
    test "update with passed data", %{proxy: proxy} do
      AccessProxy.get!(proxy)
      AccessProxy.update(proxy, 24)
      assert 24 == AccessProxy.get(proxy)
    end

    test "update with a function", %{proxy: proxy} do
      AccessProxy.get!(proxy)
      AccessProxy.update(proxy, fn current -> current + 24 end)
      assert 66 == AccessProxy.get(proxy)
    end
  end

  describe "get!" do
    test "are executed in sequence", %{proxy: proxy} do
      1..3
      |> Enum.map(fn _n ->
        Task.async(fn ->
          value = AccessProxy.get!(proxy)
          Process.sleep(100)
          :ok = AccessProxy.update(proxy, value + 1)
        end)
      end)
      |> Task.await_many()

      assert 45 == AccessProxy.get()
    end

    test "allow update only after get!", %{proxy: proxy} do
      value = AccessProxy.get(proxy)
      assert {:error, _} = AccessProxy.update(proxy, value + 1)
      assert 42 == AccessProxy.get(proxy)
    end

    test "get never blocks", %{proxy: proxy} do
      result =
        [
          Task.async(fn ->
            value = AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.update(proxy, value + 1)
            AccessProxy.get()
          end),
          Task.async(fn ->
            Process.sleep(10)
            AccessProxy.get()
          end),
          Task.async(fn ->
            value = AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.update(proxy, value + 1)
            AccessProxy.get()
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [43, 42, 44] = result
    end

    test "remove lock if current client crashes", %{proxy: proxy, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = AccessProxy.get!(proxy)
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.update(proxy, value + 1)
            AccessProxy.get()
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [exit: :upps, ok: 43] = result
    end

    test "remove from requests if queued client crashes", %{proxy: proxy, supervisor: supervisor} do
      result =
        [
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.update(proxy, value + 1)
            AccessProxy.get()
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [1], fn _n ->
            _value = AccessProxy.get!(proxy)
            Process.sleep(10)
            Process.exit(self(), :upps)
          end),
          Task.Supervisor.async_stream_nolink(supervisor, [2], fn _n ->
            value = AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.update(proxy, value + 1)
            AccessProxy.get()
          end)
        ]
        |> Enum.map(&Enum.to_list(&1))
        |> List.flatten()

      assert [ok: 43, exit: :upps, ok: 44] = result
    end

    test "timeouted request should not be able to update", %{agent: agent} do
      proxy =
        start_supervised!(
          {AccessProxy, [name: :fast_proxy_access, agent: agent, max_duration: 50]},
          id: :fast_proxy_access
        )

      [
        Task.async(fn ->
          value = AccessProxy.get!(proxy)
          Process.sleep(100)
          {:error, _msg} = AccessProxy.update(proxy, value + 10)
        end),
        Task.async(fn ->
          value = AccessProxy.get!(proxy)
          :ok = AccessProxy.update(proxy, value + 1)
        end),
        Task.async(fn ->
          value = AccessProxy.get!(proxy)
          :ok = AccessProxy.update(proxy, value + 1)
        end)
      ]
      |> Task.await_many()

      assert 44 == AccessProxy.get()
    end

    test "release exclusive lock", %{proxy: proxy} do
      result =
        [
          Task.async(fn ->
            AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.release(proxy)
            AccessProxy.get()
          end),
          Task.async(fn ->
            value = AccessProxy.get!(proxy)
            Process.sleep(100)
            :ok = AccessProxy.update(proxy, value + 1)
            AccessProxy.get()
          end)
        ]
        |> Enum.map(&Task.await(&1))

      assert [42, 43] = result
    end
  end
end
