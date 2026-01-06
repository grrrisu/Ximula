# Ximula

## Overview

Ximula is an Elixir simulation framework that separates **what to simulate** (pure functions) from **how to execute** (parallelism, locking, scheduling). It provides composable abstractions with built-in observability through Telemetry and PubSub.

## Core Architecture

### Three Levels of Abstraction

```
┌─────────────────────────────────────────────────────────────┐
│ QUEUE/LOOP LEVEL                                            │
│ ────────────────                                            │
│ Scheduling & Orchestration: WHEN and WHAT                   │
│                                                             │
│ • Defines intervals (run every N milliseconds)              │
│ • Filters data (which entities to process)                  │
│ • Orchestrates pipeline execution                           │
│ • Managed by Loop GenServer                                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ PIPELINE/STAGE LEVEL                                        │
│ ────────────────────                                        │
│ Coordination & Execution Strategy: HOW                      │
│                                                             │
│ • Sequences stages (stage 1 → stage 2 → ...)                │
│ • Adapters determine execution (parallel, single, locked)   │
│ • Manages telemetry and event notifications                 │
│ • Static configuration (built once)                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP LEVEL                                                  │
│ ──────────                                                  │
│ Simulation Logic: PURE FUNCTIONS                            │
│                                                             │
│ • Implements game/simulation rules                          │
│ • Receives %Change{}, returns %Change{}                     │
│ • No side effects (reads from data, accumulates changes)    │
│ • Composable (step 1 → step 2 → step 3)                     │
└─────────────────────────────────────────────────────────────┘
```

## Content

* Objects: Grid and Torus
* Realm: Gatekeeper
* Sim: Loop, Queue, Pipeline with stage and steps, Change and TaskRunner

## Livebook

see [livebook](livebooks/ximula.livemd)

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ximula` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ximula, "~> 0.5.0"}
  ]
end
```

## Configuration

### Simulation DSL

Ximula provides a declarative DSL for defining simulations through the `use Ximula.Sim` macro:

```elixir
defmodule MySimulation do
  use Ximula.Sim
  
  simulation do
    # Shared configuration for all stages
    default(gatekeeper: :my_gatekeeper, pubsub: :my_pubsub)
    
    # Define a pipeline (sequential stages)
    pipeline :growth do
      notify(:event_metric)  # Pipeline-level telemetry + events
      
      # Stage 1: Vegetation growth (with locking)
      stage :vegetation, :gatekeeper do
        notify_all(:event_metric)
        notify_entity(:event_metric, &filter_fn/1)
        read_fun(&MySimulation.read_field/2)
        write_fun(&MySimulation.write_field/2)
        step(MySimulation, :grow_crops)
        step(MySimulation, :consume_water)
      end
      
      # Stage 2: Movement (single aggregated entity)
      stage :world_events, :single do
        step(MySimulation, :calculate_season)
      end
    end
    
    # Schedule pipeline execution
    queue :normal, 1000 do
      run_pipeline(:growth, supervisor: :my_task_supervisor) do
        MySimulation.get_positions(:my_gatekeeper)
      end
    end
    
    # Direct function execution (no pipeline)
    queue :urgent, 100 do
      run do
        MySimulation.urgent_check()
      end
    end
  end
end
```

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
