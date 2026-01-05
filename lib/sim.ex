defmodule Ximula.Sim do
  @moduledoc """
  DSL for defining simulations with pipelines and queues.

  ## Architecture
  ```
  simulation          Top-level container
    ├─ default()      Shared configuration
    ├─ pipeline       Named sequence of stages
    │   └─ stage      Processing unit with adapter
    │       └─ step   Pure simulation function
    └─ queue          Scheduled execution
        └─ run_*      What to execute
  ```

  ## Example:
  ```elixir
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

        stage :movement, :single do
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
  ```
  """
  alias Ximula.Sim.{Pipeline, Queue}

  defmacro __using__(_opts) do
    quote do
      import Ximula.Sim
      Module.register_attribute(__MODULE__, :sim_config, accumulate: false)
      Module.register_attribute(__MODULE__, :current_queue, accumulate: false)
      Module.register_attribute(__MODULE__, :current_pipeline, accumulate: false)
      Module.register_attribute(__MODULE__, :current_stage, accumulate: false)
      @before_compile Ximula.Sim
    end
  end

  defmacro simulation(do: block) do
    quote do
      @sim_config %{pipelines: %{}, queues: []}
      unquote(block)
      @current_queue nil
      @current_pipeline nil
      @current_stage nil
    end
  end

  @doc """
  Sets default values that cascade to all pipelines, stages, and steps.

  ## Cascading behavior:
  - `gatekeeper:` - Available to all stages using :gatekeeper adapter
  - `pubsub:` - Threaded through to notification system
  - Custom keys are merged with Keyword.merge/2 at each level

  ## Example:
      default(gatekeeper: :my_world, pubsub: :my_pubsub, custom: :value)

      # gatekeeper and pubsub are now available in all child elements
  """
  defmacro default(default) do
    quote do
      @sim_config Map.put_new(@sim_config, :default, unquote(default))
    end
  end

  defmacro queue(name, interval \\ 1_000, do: block) do
    quote do
      @current_queue %Queue{name: unquote(name), interval: unquote(interval)}
      unquote(block)
      @sim_config Map.update(@sim_config, :queues, [], &[@current_queue | &1])
    end
  end

  defmacro run_pipeline(name, opts, do: data_fun) do
    Keyword.has_key?(opts, :supervisor) ||
      raise ArgumentError, "You must provide a :supervisor option to run_pipeline/2"

    quote do
      Map.has_key?(@sim_config[:pipelines], unquote(name)) ||
        raise ArgumentError, "Pipeline #{unquote(name)} not defined"

      @current_queue Map.put(
                       @current_queue,
                       :func,
                       {:pipeline, unquote(name), unquote(opts), unquote(Macro.escape(data_fun))}
                     )
    end
  end

  defmacro run(do: block) do
    quote do
      @current_queue Map.put(
                       @current_queue,
                       :func,
                       {:run, unquote(Macro.escape(block))}
                     )
    end
  end

  defmacro pipeline(name, do: block) do
    quote do
      name = unquote(name)
      opts = Keyword.merge(@sim_config[:default], name: name)
      @current_pipeline Pipeline.new_pipeline(opts)
      unquote(block)
      @sim_config put_in(@sim_config, [:pipelines, name], @current_pipeline)
    end
  end

  defmacro stage(name, adapter, do: block) do
    quote do
      opts =
        Keyword.merge(@sim_config[:default],
          name: unquote(name),
          adapter: unquote(adapter) |> stage_adapter()
        )

      @current_stage unquote(name)
      @current_pipeline Pipeline.add_stage(@current_pipeline, opts)
      unquote(block)
    end
  end

  defmacro read_fun(read_fun) do
    quote do
      @current_pipeline put_in(
                          @current_pipeline,
                          [:stages, Access.filter(&(&1.name == @current_stage)), :read_fun],
                          unquote(Macro.escape(read_fun))
                        )
    end
  end

  defmacro write_fun(write_fun) do
    quote do
      @current_pipeline put_in(
                          @current_pipeline,
                          [:stages, Access.filter(&(&1.name == @current_stage)), :write_fun],
                          unquote(Macro.escape(write_fun))
                        )
    end
  end

  defmacro step(module, function, opts \\ []) do
    quote do
      opts = Keyword.merge(@sim_config[:default], unquote(opts))

      @current_pipeline Pipeline.add_step(
                          @current_pipeline,
                          unquote(module),
                          unquote(function),
                          opts
                        )
    end
  end

  defmacro notify(type) do
    quote do
      @current_pipeline Map.put(@current_pipeline, :notify, unquote(type))
    end
  end

  defmacro notify_all(type) do
    quote do
      @current_pipeline put_in(
                          @current_pipeline,
                          [:stages, Access.filter(&(&1.name == @current_stage)), :notify, :all],
                          unquote(type)
                        )
    end
  end

  defmacro notify_entity(type, filter) do
    quote do
      @current_pipeline put_in(
                          @current_pipeline,
                          [
                            :stages,
                            Access.filter(&(&1.name == @current_stage)),
                            :notify,
                            :entity
                          ],
                          {unquote(type), unquote(Macro.escape(filter))}
                        )
    end
  end

  def stage_adapter(adapter) do
    case adapter do
      :gatekeeper -> Ximula.Sim.StageAdapter.Gatekeeper
      :grid -> Ximula.Sim.StageAdapter.Grid
      :single -> Ximula.Sim.StageAdapter.Single
      module when is_atom(module) -> module
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defp convert_ast(pipeline, path) do
        update_in(pipeline, [:stages, Access.all()] ++ List.wrap(path), fn fun ->
          case fun do
            {type, ast} when is_tuple(ast) -> {type, code_eval_quoted(ast)}
            ast when is_tuple(ast) -> code_eval_quoted(ast)
            :none -> :none
            nil -> nil
          end
        end)
      end

      defp code_eval_quoted(ast) do
        Code.eval_quoted(ast, [], __ENV__) |> elem(0)
      end

      @doc """
      Returns all queues defined in the simulation block.

      Queues are returned as a list of `%Queue{}` structs with their functions
      converted from AST to executable code.

      ## Example
          queues = MySimulation.build_queues()
          Enum.each(queues, &Loop.add_queue(:my_loop, &1))
      """
      def build_queues() do
        pipelines = build_pipelines()

        Enum.reduce(@sim_config.queues, [], fn queue, acc ->
          queue = convert_block(queue, pipelines)
          [queue | acc]
        end)
      end

      defp convert_block(
             %Queue{func: {:pipeline, pipeline_name, opts, data_fun}} = queue,
             pipelines
           ) do
        case Map.fetch(pipelines, pipeline_name) do
          {:ok, pipeline} ->
            Queue.add_pipeline(queue, pipeline, %{data: code_eval_quoted(data_fun), opts: opts})

          _ ->
            queue
        end
      end

      defp convert_block(%Queue{func: {:run, fun}} = queue, _pipelines) do
        Map.put(queue, :func, fn ->
          code_eval_quoted(fun)
        end)
      end

      @doc """
      Returns all pipelines defined in the simulation block.

      Pipelines are returned as a map with pipeline names as keys.
      All function captures (read_fun, write_fun, filters) are converted
      from AST to executable functions.

      ## Example
          pipelines = MySimulation.build_pipelines()
          Pipeline.execute(pipelines.growth, data)
      """
      def build_pipelines() do
        Enum.reduce(@sim_config.pipelines, %{}, fn {name, pipeline}, acc ->
          pipeline =
            pipeline
            |> convert_ast(:read_fun)
            |> convert_ast(:write_fun)
            |> convert_ast([:notify, :entity])

          Map.put_new(acc, name, pipeline)
        end)
      end
    end
  end
end
