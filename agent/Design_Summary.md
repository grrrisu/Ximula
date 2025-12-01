# Ximula.Sim - Design Summary

## Core Concept
A composable, pipeline-based simulation library for Elixir that separates simulation logic (pure functions) from execution strategy (parallel/sequential), state management (fault-tolerant agents), and event handling (declarative side effects).

---

## Architecture Overview

```
┌─────────────────┐
│  Loop (GenServer)│  ← Ephemeral orchestration (can restart)
│  - queues        │     Manages: timers, tasks, runtime state
│  - timers        │
│  - tasks         │
└────────┬─────────┘
         │
         ├──────────────────────┬─────────────────────┐
         │                      │                     │
┌────────▼──────────┐    ┌──────▼──────────────┐ ┌──▼──────────┐
│ StateAgent        │    │ EventManager        │ │ Pipelines   │
│ (Persistent)      │    │ (Persistent)        │ │ (Static)    │
│ - grid            │    │ - event handlers    │ │ - config    │
│ - tick counter    │    │ - side effects      │ │ - domain    │
│ - partitions      │    │ - migration logic   │ │   logic     │
│ - stats           │    └─────────────────────┘ └─────────────┘
└───────────────────┘
```

**Key Design**: State and configuration survive Loop crashes. Partitions live with simulation state because they represent current field activity levels.

---

## Three Levels of Execution

### Queue / Loop (Timing & Orchestration)
* **Purpose**: Schedules when pipelines run
* **Properties**: name, interval, timer, task
* **Implementation**: GenServer with dynamic queue management
* **Execution**: Each queue runs in its own supervised task
* **API**: `Loop.add_queue(loop, queue)`, `Loop.start_sim(loop)`
* **Example**: Run "active" partition every 100ms, "static" partition every 10s
* **State**: Ephemeral (timers, task references) - can crash and restart

### Pipeline / Stage (Coordination & Execution Strategy)
* **Purpose**: Defines what runs and how (sequential stages)
* **Properties**: stage sequence, stage adapter, notification config
* **Execution**: 
  - Calls `TaskRunner` for parallel execution
  - Adapters handle data shape (Grid, Single, Gatekeeper)
  - Aggregates and applies changes
* **API**: `Pipeline.execute(pipeline, state)`
* **Example**: Stage 1: grow_crops → Stage 2: consume_food
* **State**: Static (built once, stored as module functions or config)

### Simulation / Step (Pure Logic)
* **Purpose**: Implements game/simulation rules
* **Properties**: Pure functions, no side effects
* **Signature**: `def step(%Change{data, changes}, opts)`
* **Returns**: `%Change{changes: %{key: value}}`
* **API**: `Vegetation.grow_crops(change)`
* **Example**: Calculate crop growth based on water + soil
* **Events**: Emit telemetry/pubsub events for significant changes

**The execution flow:**
```
Loop (when? which partition?)
  └─> Pipeline (what stages? how to execute?)
       └─> Stage Adapter (parallel? single? locked?)
            └─> TaskRunner (low-level parallel tasks)
                 └─> Simulation Steps (pure logic + events)
                      └─> EventManager (migrations, side effects)
```

---

## Key Design Decisions

### 1. State Management & Fault Tolerance

**StateAgent (Persistent)**
```elixir
%{
  grid: %Grid{...},              # Simulation state
  tick: 42,                      # Current tick
  partitions: %{                 # Which fields in which queue
    "active" => MapSet[{3,5}],
    "slow" => MapSet[...],
    "static" => MapSet[...]
  },
  stats: %{}
}
```

**Why partitions live here**: They represent *current* field activity levels and evolve during simulation. When a tundra field becomes a settlement, its partition membership changes - that's simulation state, not configuration.

**Loop (Ephemeral)**
```elixir
%{
  running: true,
  queues: [%Queue{name: "active", interval: 100, timer: ref, task: task}],
  pipelines: MyApp.Pipelines,   # Reference to static pipelines
  state_agent: StateAgent,
  event_manager: EventManager,
  supervisor: TaskSupervisor
}
```

**Benefits:**
- Loop crashes don't lose simulation state
- State can be persisted/restored independently
- Clear separation: orchestration vs data

---

### 2. Static Partitioning with Dynamic Migration

**Spatial optimization**: Instead of processing all 10,000 fields every tick, partition by activity level:

```elixir
# Different queues with different intervals
queues = [
  %Queue{name: "active", interval: 100},    # 50 active fields
  %Queue{name: "slow", interval: 1000},     # 200 plains fields
  %Queue{name: "static", interval: 10000}   # 9750 ocean/mountain fields
]

# Queue execution only processes its partition
Pipeline.execute(pipeline, %{
  data: grid,
  opts: [
    positions: StateAgent.get_partition("active"),  # Just these 50
    tick: 42
  ]
})
```

**Migration via Events**: When field activity changes, EventManager updates partitions:

```elixir
# Simulation emits event
def settle_field(%Change{} = change) do
  :telemetry.execute([:my_app, :field, :settled], %{}, %{position: {15, 20}})
  Change.set(change, :population, 10)
end

# EventManager handles migration
EventHandler.migration(
  name: "field_settled",
  on: [:my_app, :field, :settled],
  from: "static",
  to: "active"
)
# → StateAgent.migrate_position({15, 20}, "static", "active")
```

---

### 3. Event-Driven Side Effects

**EventManager** - Declarative event handling with DSL:

```elixir
defmodule MyApp.EventHandlers do
  def migration_handlers do
    [
      # Simple migration
      EventHandler.migration(
        name: "settlement_created",
        on: [:my_app, :field, :settled],
        from: "static",
        to: "active"
      ),
      
      # Conditional migration
      EventHandler.migration(
        name: "high_population",
        on: [:my_app, :field, :population_changed],
        when: &(&1.population > 100),
        from: "slow",
        to: "active"
      ),
      
      # Custom handler
      EventHandler.on([:my_app, :combat, :started], fn event, state ->
        Logger.info("Combat at #{inspect(event.position)}")
        # Custom side effects
      end)
    ]
  end
end
```

**Benefits:**
- Simulations stay pure (just emit events)
- Migration logic is declarative and testable
- Easy to add new handlers without changing simulation code
- All side effects go through one observable place

---

### 4. Two-Level Pipeline Architecture

**Pipeline (Orchestration Level)**
- Defines sequence of stages that run in order
- Each stage is a complete execute → simulate → reduce cycle
- Ensures dependencies between stages (e.g., grow crops before feeding population)
- Static definition (module functions or config)

**Stage (Logic Level)**
- Defines steps within a simulation
- Pure functions with pattern matching
- Steps run sequentially within entity, entities processed in parallel
- Adapters handle different data structures (Grid, Single, Gatekeeper)

---

### 5. Separation of Concerns

**Simulation Layer (Pure)**
- No processes, no side effects, no state
- Pattern-matched functions: `def step(%Change{data, changes}, opts)`
- Returns: `%Change{changes: %{key: value}}`
- Emits telemetry/pubsub events for significant changes
- Can declare cross-entity operations for Gatekeeper coordination

**Execution Layer (Stateful)**
- Handles Tasks, GenServers, orchestration
- Manages parallelism across entities via TaskRunner
- Integrates with Gatekeeper for cross-entity writes
- Different stage adapters for different data structures:
  - `StageAdapter.Single` - One entity, direct return
  - `StageAdapter.Grid` - Grid positions, parallel via `Grid.map`
  - `StageAdapter.Gatekeeper` - Locked entities, atomic updates
- Each adapter handles its own reduction (tightly coupled to data structure)

**State Layer (Persistent)**
- StateAgent holds grid, tick, partitions, stats
- Survives Loop crashes
- Can be persisted to disk/database
- Single source of truth

**Event Layer (Coordination)**
- EventManager listens to events
- Executes declarative handlers
- Coordinates migrations and side effects
- Decouples simulation from orchestration

---

### 6. Read/Write Model

**Read (Tick N-1):**
- All processes read immutable state from previous tick
- Safe for parallel reads via StateAgent
- Passed as `original_data` parameter in Change struct

**Write (Tick N):**
- Changes accumulate in Change struct
- Passed as `accumulated_changes` parameter
- If step B depends on step A in same tick, reads from `accumulated_changes`
- Changes held until end of pipeline, then applied atomically

**Cross-Entity Writes:**
- Use Gatekeeper for coordination
- StageAdapter.Gatekeeper handles locking
- Atomic updates via `Gatekeeper.update_multi`

---

### 7. Observability via Telemetry & PubSub

**Two complementary systems for different observability needs:**

#### Telemetry (Metrics & Performance)
**Use for**: Metrics, performance monitoring, system health, integration with observability tools

**Events emitted:**
```elixir
# Pipeline level
[:ximula, :sim, :pipeline, :start]
[:ximula, :sim, :pipeline, :stop]         # metadata: %{name: ...}, measurements: %{duration: ...}

# Stage level
[:ximula, :sim, :pipeline, :stage, :start]
[:ximula, :sim, :pipeline, :stage, :stop] # metadata: %{stage_name: ...}, measurements: %{duration: ...}

# Entity stage level (all entities in stage)
[:ximula, :sim, :pipeline, :stage, :entity, :start]
[:ximula, :sim, :pipeline, :stage, :entity, :stop]  # measurements: %{duration: ..., ok: count, failed: count}

# Step level (per entity)
[:ximula, :sim, :stage, :step, :start]
[:ximula, :sim, :stage, :step, :stop]     # metadata: %{entity: ..., module: ..., function: ...}

# Errors
[:ximula, :sim, :stage, :failed_steps]    # measurements: %{failed_count: ...}
```

**Integration**: Works with LiveDashboard, StatsD, Prometheus, custom reporters

#### PubSub (Domain Events & Real-time Updates)
**Use for**: Real-time UI updates (LiveView), custom domain events, entity state changes

**Topic Structure:**
```
sim:pipeline:#{name}
sim:pipeline:stage:#{stage_name}
sim:pipeline:stage:#{stage_name}:entity
sim:pipeline:stage:entity:step
```

**Event Types:**
- `:pipeline_completed` (with result)
- `:stage_completed` (with aggregated changes)
- `:entity_stage_completed` (for entity-level updates)
- `:step_completed` (per entity, per step)
- Custom domain events (`:field_settled`, `:combat_started`, etc.)

**Notification Configuration:**
- Pipeline level: `:none`, `:metric`, `:event`, `:event_metric`
- Stage level: `%{all: :metric, entity: :event}`
- Step level: `{:metric, entity}` (entity required)

**When to use which:**
- **Telemetry**: Always on, lightweight, for metrics and performance
- **PubSub**: Opt-in, heavier payloads, for domain events and UI updates

---

### 8. Parallelization Rules

**✅ Can parallelize:**
- Same simulation across different entities (grow crops on all fields in partition)
- Different simulations on same entity (crops + population on field A)

**❌ Cannot parallelize:**
- Same simulation on same entity twice (never two crop growth tasks on field A)

**Sequential when needed:**
- Stages with dependencies run in order
- Within each stage, entities processed in parallel
- Within each entity, steps run sequentially

**Spatial optimization:**
- Only process positions in queue's partition
- Skip 90%+ of inactive fields entirely
- Different update frequencies for different activity levels

---

### 9. Configuration

**Global (Application Level):**
```elixir
config :ximula_sim,
  pubsub: MyApp.PubSub,
  simulation_name: :world,
  # PubSub events (opt-in, for domain events)
  broadcast_events: [:stage_complete],
  # Telemetry always enabled for metrics
  telemetry_prefix: [:my_app, :ximula, :sim]
```

**Pipeline (Static - Module or Config):**
```elixir
defmodule MyApp.Pipelines do
  def world_pipeline do
    Pipeline.new_pipeline(name: "world", notify: :metric)
    |> Pipeline.add_stage(
      adapter: StageAdapter.Grid,
      notify: %{all: :metric, entity: :none},
      name: "vegetation"
    )
    |> Pipeline.add_step(VegetationSim, :grow)
  end
end
```

**StateAgent (Initial State):**
```elixir
{StateAgent, 
  name: MyApp.SimState,
  initial_grid: Grid.new(100, 100),
  partitions: %{
    "active" => MapSet.new([{3,5}, {4,5}]),
    "slow" => MapSet.new([...]),
    "static" => MapSet.new([...])
  }
}
```

**EventManager (Event Handlers):**
```elixir
{EventManager,
  name: MyApp.EventManager,
  handlers: MyApp.EventHandlers.all_handlers(),
  state_agent: MyApp.SimState,
  loop: MyApp.SimLoop
}
```

---

## Data Flow Example

**Tick N execution with partitioning:**

1. **Tick Start (Active Queue)**
   - Timer fires: `{:tick, "active"}`
   - Loop fetches:
     - Pipeline: `MyApp.Pipelines.world_pipeline()`
     - Partition: `StateAgent.get_partition("active")` → `[{3,5}, {4,5}]` (50 fields)
     - Grid: `StateAgent.get_grid()`
     - Tick: `StateAgent.get_tick()` → `42`

2. **Stage 1: vegetation**
   - Broadcast `:stage_start`
   - `StageAdapter.Grid.get_data` extracts only partition positions
   - TaskRunner spawns 50 tasks (not 10,000!)
   - Each field runs VegetationSim pipeline:
     - `absorb_water(data, %{}, opts)` → `%{changes: %{water: -1}}`
     - `grow_plants(data, %{water: -1}, opts)` → `%{changes: %{growth: +5}}`
     - Emits: `:telemetry.execute([:my_app, :vegetation, :grew], ...)`
   - Collect changes from 50 fields
   - Adapter reduces via `Grid.apply_changes(grid, results)`
   - Broadcast `:stage_complete`

3. **Event Processing**
   - EventManager receives telemetry event
   - Checks handlers, finds migration rule
   - `StateAgent.migrate_position({15, 20}, "static", "active")`
   - Partition updated for next tick

4. **State Update**
   - `StateAgent.update_grid(new_grid)`
   - Increments tick counter: `43`
   - Returns updated grid

5. **Next Tick (Static Queue - 10 seconds later)**
   - Timer fires: `{:tick, "static"}`
   - Processes 9750 static fields
   - Most return `:no_change` quickly
   - Rare events trigger migrations

6. **Tick Complete**
   - Final state for tick N committed
   - Broadcast `:tick_complete`
   - Becomes immutable read state for tick N+1

---

## Module Structure

```
Ximula.Sim/
├── Pipeline.ex                    # Pipeline builder & executor
├── TaskRunner.ex                  # Low-level parallel task execution
│
├── StageAdapter/                  # Data structure adapters
│   ├── Single.ex                  # Single entity: get_data/1, reduce_data/2
│   ├── Grid.ex                    # Grid parallel: filters by partition
│   └── Gatekeeper.ex              # Locked entities: atomic updates
│
├── StateAgent.ex                  # Persistent state (grid, tick, partitions)
├── EventManager.ex                # Event-driven side effects
├── EventHandler.ex                # Handler DSL & struct
│
├── Loop.ex                        # Ephemeral orchestration (GenServer)
├── Queue.ex                       # Queue definition struct
│
├── Change.ex                      # Changeset utilities
├── Notify.ex                      # Telemetry + PubSub helpers
│
└── Telemetry.ex                   # Telemetry event definitions
```

---

## Key Requirements

### Functional Requirements
- Support hierarchical simulations (world → region → field)
- Allow parallel execution of independent entities
- Ensure sequential execution of dependent stages
- Handle cross-entity operations with locking
- Provide observability without coupling
- Support spatial optimization via partitioning
- Enable dynamic field migration between activity levels
- Survive Loop crashes without losing simulation state

### Technical Requirements
- Pure simulation functions (no side effects)
- Immutable data throughout execution
- Changes tracked separately from original data
- Integration with Ximula.Gatekeeper for coordination
- Telemetry integration for metrics and performance monitoring
- Phoenix.PubSub for domain events and real-time updates
- Fault-tolerant state management via Agents
- Event-driven side effects via EventManager
- Configurable at application and pipeline levels

### Performance Considerations
- Spatial partitioning: skip 90%+ of inactive fields
- Different update frequencies for different activity levels
- Minimize event broadcasting (selective, not every change)
- Reduction happens per stage (not per step)
- Support parallel task execution via TaskRunner
- Efficient partition lookups via MapSet

### Developer Experience
- Clear separation of concerns
- Declarative DSL for pipelines and event handlers
- Pattern matching for simulation logic
- Flexible subscription model for observation
- Easy to test (pure functions + declarative handlers)
- Easy to debug (granular telemetry events)
- Easy to extend (add queues, handlers, stages at runtime)

---

## Supervision Tree

```elixir
children = [
  # Persistent state (survives Loop crashes)
  {Ximula.Sim.StateAgent, 
    name: MyApp.SimState,
    initial_grid: grid,
    partitions: initial_partitions()
  },
  
  # Event coordination
  {Ximula.Sim.EventManager,
    name: MyApp.EventManager,
    handlers: MyApp.EventHandlers.all_handlers(),
    state_agent: MyApp.SimState,
    pubsub: MyApp.PubSub
  },
  
  # Task execution
  {Task.Supervisor, name: MyApp.TaskSupervisor},
  
  # Ephemeral orchestration (can crash/restart)
  {Ximula.Sim.Loop,
    name: MyApp.SimLoop,
    pipelines: MyApp.Pipelines,
    state_agent: MyApp.SimState,
    event_manager: MyApp.EventManager,
    supervisor: MyApp.TaskSupervisor
  }
]

Supervisor.start_link(children, strategy: :one_for_one)
```

---

## Open Questions for Implementation

1. **Partition initialization**: How to classify fields into partitions at startup? Manual config? Heuristic?
2. **Migration batching**: Should migrations be applied immediately or batched per tick?
3. **Persistence**: Should StateAgent periodically dump to disk? ETS? External DB?
4. **Error handling**: How to handle simulation step failures? Retry? Rollback stage?
5. **History**: Should the library track history of ticks for replay/debugging?
6. **Dynamic pipelines**: Allow runtime pipeline modification or keep them static?
7. **Step metadata**: Should steps declare `@effects` and `@reads` for validation?
8. **Validation**: Should changes be validatable (like Ecto changesets)?