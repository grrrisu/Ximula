defmodule Ximula.SimTest do
  use ExUnit.Case, async: true

  alias Ximula.Sim.{Change, Pipeline}

  defmodule TestSimulation do
    use Ximula.Sim

    def get_data(_gatekeeper) do
      [%{one: 1}, %{one: 2}, %{one: 3}]
    end

    def get_value(%{one: value}, _gatekeeper) do
      %{one: value}
    end

    def put_value(%{one: value}, _gatekeeper) do
      %{one: value}
    end

    def sim_vegetation(change) do
      Change.change_by(change, :one, 1)
    end

    def sim_herbivore(change) do
      Change.change_by(change, :one, 1)
    end

    def sim_predator(change) do
      Change.change_by(change, :one, 1)
    end

    def sim_movement(change) do
      Change.change_by(change, :one, 1)
    end

    def sim_crash(change) do
      Change.change_by(change, :one, 1)
    end

    def notify_filter(_input) do
      # filter the input
    end

    simulation do
      default(gatekeeper: :my_world, pubsub: :my_pubsub)

      pipeline :growth do
        notify(:metric)

        stage :flora_fauna, :gatekeeper do
          read_fun(&TestSimulation.get_value/2)
          write_fun(&TestSimulation.put_value/2)
          step(TestSimulation, :sim_vegetation)
          step(TestSimulation, :sim_herbivore)
          step(TestSimulation, :sim_predator)
        end

        stage :movement, :single, more: :options do
          notify_all(:metric)
          notify_entity(:event_metric, &TestSimulation.notify_filter/1)
          step(TestSimulation, :sim_movement)
          step(TestSimulation, :sim_crash, notify: {:event, &TestSimulation.notify_filter/1})
        end
      end

      queue :normal do
        run_pipeline(:growth, supervisor: SimTest.Supervisor) do
          TestSimulation.get_data(:gatekeeper)
        end
      end

      queue :urgent, 500 do
        run do
          TestSimulation.get_data(:gatekeeper)
          |> Enum.map(fn item ->
            %{one: item.one + 10}
          end)
        end
      end
    end
  end

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: SimTest.Supervisor})
    %{supervisor: supervisor}
  end

  test "build pipeline", %{supervisor: supervisor} do
    pipelines = TestSimulation.build_pipelines()

    assert %{
             growth: %{
               name: :growth,
               notify: :metric,
               pubsub: :my_pubsub,
               stages: [
                 %{
                   name: :flora_fauna,
                   notify: %{all: :none, entity: :none},
                   gatekeeper: :my_world,
                   pubsub: :my_pubsub,
                   adapter: Ximula.Sim.StageAdapter.Gatekeeper,
                   on_error: :raise,
                   read_fun: _,
                   write_fun: _,
                   steps: [
                     %{
                       function: :sim_vegetation,
                       module: Ximula.SimTest.TestSimulation,
                       notify: {:none, nil},
                       pubsub: :my_pubsub
                     },
                     %{
                       function: :sim_herbivore,
                       module: Ximula.SimTest.TestSimulation,
                       notify: {:none, nil},
                       pubsub: :my_pubsub
                     },
                     %{
                       function: :sim_predator,
                       module: Ximula.SimTest.TestSimulation,
                       notify: {:none, nil},
                       pubsub: :my_pubsub
                     }
                   ]
                 },
                 %{
                   name: :movement,
                   notify: %{all: :metric, entity: {:event_metric, _}},
                   gatekeeper: :my_world,
                   pubsub: :my_pubsub,
                   adapter: Ximula.Sim.StageAdapter.Single,
                   on_error: :raise,
                   more: :options,
                   steps: [
                     %{
                       function: :sim_movement,
                       module: Ximula.SimTest.TestSimulation,
                       notify: {:none, nil},
                       pubsub: :my_pubsub
                     },
                     %{
                       function: :sim_crash,
                       module: Ximula.SimTest.TestSimulation,
                       notify: {:event, _},
                       pubsub: :my_pubsub
                     }
                   ]
                 }
               ]
             }
           } = pipelines

    assert {:ok, %{one: _}} =
             Pipeline.execute(pipelines.growth, %{
               data: [%{one: 1}, %{one: 2}, %{one: 3}],
               opts: [supervisor: supervisor]
             })
  end

  test "build queues" do
    queues = TestSimulation.build_queues()

    assert [
             %Ximula.Sim.Queue{
               name: :normal,
               func: _,
               interval: 1000
             },
             %Ximula.Sim.Queue{
               name: :urgent,
               func: _,
               interval: 500
             }
           ] = queues

    assert {:ok, %{one: _one}} = queues |> List.first() |> Ximula.Sim.Queue.execute([])

    assert [%{one: 11}, %{one: 12}, %{one: 13}] ==
             queues |> List.last() |> Ximula.Sim.Queue.execute([])
  end
end
