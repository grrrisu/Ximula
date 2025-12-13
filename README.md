# Ximula

A helper library for various simulation helpers.

## Content

* Objects: Grid and Torus
* Realm: Gatekeeper
* Sim: Loop, Queue, Pipeline with stage and steps, Change and TaskRunner

## Livebook

see [livebook](livebooks/sim.livemd)

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ximula` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ximula, "~> 0.4.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ximula>.

## Configuration

### PubSub (Optional)

If you want to receive domain events via PubSub:
```elixir
# config/config.exs
config :ximula, :pubsub, MyApp.PubSub
```

Or configure per-notification (pipeline, stage, step):
```elixir
pipeline = 
  Pipeline.new_pipeline(
    name: "My Sim",
    notify: :event,
    pubsub: MyApp.PubSub
  )
```

### Telemetry

Ximula emits telemetry events at multiple levels. Attach handlers:
```elixir
:telemetry.attach_many(
  "my-sim-handler",
  [
    [:ximula, :sim, :queue, :stop],
    [:ximula, :sim, :pipeline, :stop],
    [:ximula, :sim, :pipeline, :stage, :stop]
  ],
  &MyApp.Telemetry.handle_event/4,
  %{}
)
```

### Supervisors

Ximula requires task supervisors in your supervision tree:
```elixir
children = [
  {Task.Supervisor, name: Ximula.Sim.TaskRunner.Supervisor},
  {Task.Supervisor, name: Ximula.Sim.Loop.Task.Supervisor},
  {Ximula.Sim.Loop}
]
```

For custom supervisor names, pass them explicitly:
```elixir
{Ximula.Sim.Loop, 
  supervisor: MyApp.SimLoopSupervisor,
  sim_args: [supervisor: MyApp.TaskRunnerSupervisor]
}
```