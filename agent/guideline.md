# Ximula Simulation Library - Architecture & Usage Guide

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

## Supervision Tree

```
Supervisor (strategy: :rest_for_one)
├─> Agent (MyWorld)              # Data layer - holds grid/world state
├─> Gatekeeper.Agent             # Locked access wrapper around Agent
├─> Phoenix.PubSub               # Event broadcasting
├─> Task.Supervisor (Loop)       # Supervises queue execution tasks
├─> Task.Supervisor (Runner)     # Supervises parallel step tasks
└─> Loop GenServer               # Orchestrates queue execution
```

**Strategy Rationale**: 
- If **Gatekeeper crashes** → Loop must restart (data layer is invalid, orchestration depends on it)
- If **Loop crashes** → Gatekeeper survives (world data persists, queues can be rebuilt)
- If **PubSub/TaskSupervisors crash** → Everything restarts (infrastructure failure)
- **`:rest_for_one`** ensures proper dependency chain: data → infrastructure → orchestration

## Quick Start

### 1. Define Your Simulation Using the DSL

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

**DSL Benefits**:
- Declarative configuration (clear structure)
- Compile-time validation (pipeline references checked)
- Automatic AST to runtime conversion
- Better developer experience

**Building at Runtime**:

The DSL compiles into two functions that you call at runtime:

```elixir
# Build pipeline definitions (static structures)
pipelines = MySimulation.build_pipelines()
# Returns: %{growth: %{stages: [...], name: :growth, ...}}

# Build queue definitions (with functions)
queues = MySimulation.build_queues()
# Returns: [%Queue{name: :normal, func: fn -> ... end, ...}]
```

### 2. Start the Supervision Tree

```elixir
children = [
  # Data layer
  Ximula.Gatekeeper.Agent.agent_spec(MyWorld, data: nil, name: :world),
  {Ximula.Gatekeeper.Agent, name: :my_gatekeeper, agent: :world},
  
  # Infrastructure
  {Phoenix.PubSub, name: :my_pubsub},
  {Task.Supervisor, name: :loop_supervisor},
  {Task.Supervisor, name: :my_task_supervisor},
  
  # Orchestration
  {Ximula.Sim.Loop, name: :my_loop, supervisor: :loop_supervisor}
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

### 3. Initialize and Run

```elixir
# Initialize world data
world = Ximula.Torus.create(10, 10, %{vegetation: 100, water: 50})
Ximula.Gatekeeper.Agent.direct_set(:my_gatekeeper, fn _ -> world end)

# Build and add queues
queues = MySimulation.build_queues()
Ximula.Sim.Loop.add_queues(:my_loop, queues)

# Start simulation
Ximula.Sim.Loop.start_sim(:my_loop)

# Stop simulation
Ximula.Sim.Loop.stop_sim(:my_loop)
```

## Understanding the DSL

The `simulation do` DSL is a powerful macro system that transforms declarative configuration into runtime data structures.

### How It Works

**At Compile Time**:
1. `use Ximula.Sim` registers module attributes and imports macros
2. `simulation do` block captures AST (Abstract Syntax Tree)
3. Macros like `pipeline`, `stage`, `queue` build nested structures
4. Function captures (like `&MyModule.func/2`) are stored as AST

**At Module Compilation**:
1. `@before_compile` hook generates two functions:
   - `build_pipelines/0` - Returns map of pipeline definitions
   - `build_queues/0` - Returns list of queue definitions
2. AST is converted to executable code via `Code.eval_quoted/3`

**At Runtime**:
```elixir
# Call generated functions
pipelines = MySimulation.build_pipelines()
# %{growth: %{stages: [...], name: :growth, notify: :metric, ...}}

queues = MySimulation.build_queues()
# [%Queue{name: :normal, func: fn -> ... end, interval: 1000, ...}]
```

### DSL Reference

**Simulation Block** (top-level):
```elixir
simulation do
  default(key: value, ...)     # Shared configuration
  pipeline :name do ... end    # Define pipeline
  queue :name, interval do ... end  # Define queue
end
```

**Pipeline Block**:
```elixir
pipeline :name do
  notify(:metric | :event | :event_metric)  # Optional notification
  stage :name, :adapter do ... end          # One or more stages
end
```

**Stage Block**:
```elixir
stage :name, :gatekeeper | :grid | :single | CustomAdapter do
  notify_all(:metric)                              # Optional
  notify_entity(:event, &filter/1)                 # Optional
  read_fun(&Module.read/2)                         # Gatekeeper only
  write_fun(&Module.write/2)                       # Gatekeeper only
  step(Module, :function)                          # One or more steps
  step(Module, :function, notify: {:metric, &filter/1})  # With notification
end
```

**Queue Block**:
```elixir
# With pipeline
queue :name, interval do
  run_pipeline(:pipeline_name, supervisor: :sup_name) do
    data_source_function()  # Returns data for pipeline
  end
end

# Direct function
queue :name, interval do
  run do
    custom_function()  # Runs directly, no pipeline
  end
end
```

**Default Block** (optional):
```elixir
default(
  gatekeeper: :my_gatekeeper,  # Available in all stages
  pubsub: :my_pubsub,           # Available for notifications
  custom_key: value             # Merged with Keyword.merge/2
)
```

### Compilation Example

**Source DSL**:
```elixir
defmodule Example do
  use Ximula.Sim
  
  simulation do
    default(gatekeeper: :gk)
    
    pipeline :simple do
      stage :process, :single do
        step(Example, :my_step)
      end
    end
    
    queue :tick, 1000 do
      run_pipeline(:simple, supervisor: :sup) do
        [1, 2, 3]
      end
    end
  end
  
  def my_step(%Change{} = change), do: change
end
```

**Generated Functions** (simplified):
```elixir
def build_pipelines do
  %{
    simple: %{
      stages: [
        %{
          adapter: Ximula.Sim.StageAdapter.Single,
          steps: [
            %{module: Example, function: :my_step, notify: {:none, nil}}
          ],
          name: :process
        }
      ],
      name: :simple,
      notify: :none
    }
  }
end

def build_queues do
  [
    %Ximula.Sim.Queue{
      name: :tick,
      interval: 1000,
      func: fn ->
        pipeline = Map.fetch!(build_pipelines(), :simple)
        data = [1, 2, 3]
        Ximula.Sim.Pipeline.execute(pipeline, %{
          data: data,
          opts: [gatekeeper: :gk, supervisor: :sup]
        })
      end
    }
  ]
end
```

## Stage Adapters

Adapters determine **how** entities are processed. Choose based on your data structure and coordination needs.

### Gatekeeper Adapter - Coordinated Locked Access

**Use when**: Entities need to interact, cross-entity operations, preventing race conditions

**Data flow**:
1. Queue provides list of **keys** (e.g., positions, entity IDs)
2. Each key spawns a parallel task
3. Task acquires lock on key
4. Task reads current state (holds lock)
5. Task executes all steps (still holding lock)
6. Task writes result and releases lock

**Required configuration**:
```elixir
stage :my_stage, :gatekeeper do
  read_fun(&MyModule.read_entity/2)   # (key, gatekeeper) -> entity_data
  write_fun(&MyModule.write_entity/2) # (entity_data, gatekeeper) -> :ok
end
```

**Critical: Locking Lifecycle**

```elixir
# read_fun: Acquire lock, read, KEEP HOLDING
def read_field(position, gatekeeper) do
  # Gatekeeper.lock acquires lock and DOES NOT release
  field = Gatekeeper.lock(gatekeeper, position, fn _key ->
    Agent.get(:world, &Grid.get(&1, position))
  end)
  
  # Add metadata for routing (not persisted)
  Map.put(field, :position, position)
end

# Steps execute while lock is held
def grow_crops(%Change{} = change) do
  Change.change_by(change, :vegetation, 1)
end

# write_fun: Write and RELEASE lock
def write_field(%{position: position} = field, gatekeeper) do
  # Gatekeeper.update writes and releases lock
  Gatekeeper.update(gatekeeper, position, fn _data, context ->
    Agent.update(context.agent, &Grid.put(&1, position, field))
  end)
end
```

**Performance**: Each key can be locked independently, allowing high parallelism with no contention when keys don't overlap.

### Grid Adapter - Parallel Grid Processing

**Use when**: Spatial 2D simulations with independent cells, no cross-cell interactions

**Data flow**:
1. Queue provides entire **Grid** struct
2. Adapter extracts all positions: `%{position: {x, y}, field: data}`
3. Each position spawns a parallel task
4. Tasks execute steps independently (no locking)
5. Results collected and applied back to grid

**Configuration**:
```elixir
stage :my_stage, :grid do
  step(MyModule, :process_cell)
end

# Queue provides grid directly
queue :normal do
  run_pipeline(:my_pipeline, supervisor: MySupervisor) do
    Agent.get(:world, & &1)  # Returns entire grid
  end
end
```

**When to use**:
- Grid is already in memory (not behind Gatekeeper)
- Cells process independently
- No cross-cell interactions needed
- Higher performance than Gatekeeper (no locking overhead)

### Single Adapter - Non-Parallel Execution

**Use when**: One aggregated entity, world-level calculations, orchestration between stages

**Data flow**:
1. Queue provides single entity or data structure
2. Executes as one task (not parallelized)
3. Steps run sequentially
4. Returns modified entity

**Configuration**:
```elixir
stage :world_calc, :single do
  step(MyModule, :calculate_season)
  step(MyModule, :update_global_state)
end

queue :world_tick do
  run_pipeline(:world_events, supervisor: MySupervisor) do
    %{tick: get_tick(), season: get_season()}
  end
end
```

### Adapter Decision Tree

```
Do you have multiple entities to process?
├─ No → Single Adapter
└─ Yes → Do entities need to interact or share state?
    ├─ No → Grid Adapter (if spatial) or Single with list
    └─ Yes → Gatekeeper Adapter
        └─ Is data already in memory?
            ├─ Yes → Consider Grid + manual coordination
            └─ No → Gatekeeper (data behind Agent)
```

## The Change Pattern

The `%Change{}` struct separates **reading** (from tick N-1) from **writing** (to tick N), solving the "step execution order" problem.

### Structure

```elixir
%Change{
  data: %{health: 100, food: 50},      # Original immutable data (tick N-1)
  changes: %{health: -10, food: -5}    # Accumulated changes (tick N)
}
```

### Core Functions

```elixir
# Read current value (original + accumulated changes)
health = Change.get(change, :health)  # 90 (100 - 10)

# Accumulate numeric delta (additive)
change = Change.change_by(change, :health, -20)  # Now -30 total

# Set absolute value (calculates delta)
change = Change.set(change, :health, 75)  # Stores -25 delta

# Apply all changes at end of stage
final = Change.reduce(change)  # %{health: 70, food: 45}
```

### Change Semantics

**Numeric values** (accumulate):
```elixir
change
|> Change.change_by(:health, -10)    # health: -10
|> Change.change_by(:health, -5)     # health: -15
|> Change.reduce()                   # health: 85 (100 - 15)
```

**Non-numeric values** (replace, last write wins):
```elixir
change
|> Change.set(:status, :wounded)
|> Change.set(:status, :dead)        # Last write wins
|> Change.reduce()                   # status: :dead
```

### Nested Keys

```elixir
change = %Change{
  data: %{stats: %{health: 100, mana: 50}},
  changes: %{}
}

# Use lists for nested keys
change = Change.change_by(change, [:stats, :health], -10)
health = Change.get(change, [:stats, :health])  # 90

# Works with deeper nesting
change = Change.change_by(change, [:player, :inventory, :gold], 100)
gold = Change.get(change, [:player, :inventory, :gold])

# Useful for complex entity structures
change = %Change{
  data: %{
    player: %{
      stats: %{health: 100, mana: 50},
      inventory: %{gold: 1000, items: []}
    }
  },
  changes: %{}
}
```

### Usage in Steps

```elixir
def take_damage(%Change{} = change, damage_amount) do
  current_health = Change.get(change, :health)
  
  if current_health > damage_amount do
    Change.change_by(change, :health, -damage_amount)
  else
    change
    |> Change.set(:health, 0)
    |> Change.set(:status, :dead)
  end
end

def regenerate(%Change{} = change) do
  status = Change.get(change, :status)
  
  if status != :dead do
    Change.change_by(change, :health, 5)
  else
    change  # No change
  end
end
```

### No-Change Optimization

When a step determines nothing needs to change, return `:no_change` instead of the change struct. TaskRunner automatically filters these out for better performance:

```elixir
def grow_crops(%Change{} = change) do
  water = Change.get(change, :water)
  sunlight = Change.get(change, :sunlight)
  
  # Only grow if conditions are met
  if water > 10 and sunlight > 5 do
    change
    |> Change.change_by(:vegetation, 1)
    |> Change.change_by(:water, -1)
  else
    :no_change  # Filtered out by TaskRunner, doesn't propagate
  end
end
```

**Benefits**:
- Reduces memory allocations (no change struct created)
- Reduces write operations (skip write_fun calls)
- Clearer intent (explicit "nothing to do")
- Better performance for sparse updates

### Pattern Benefits

1. **Order independence**: Steps can read from both original data and prior step changes
2. **Composability**: Steps chain naturally with `|>` operator
3. **Clarity**: Explicit separation of reads vs writes
4. **Immutability**: Original data never mutates

## Data Structures

### Grid - Bounded 2D Grid

```elixir
# Create grid
grid = Ximula.Grid.create(width, height, default_value)

# With function
grid = Ximula.Grid.create(10, 10, fn x, y -> 
  %{position: {x, y}, type: :grass}
end)

# Access
{:ok, value} = Grid.get(grid, x, y)
{:error, reason} = Grid.get(grid, -1, 5)  # Out of bounds

# Update
grid = Grid.put(grid, x, y, new_value)

# Batch updates
changes = [{{0, 0}, value1}, {{1, 1}, value2}]
grid = Grid.apply_changes(grid, changes)

# Utilities
positions = Grid.positions(grid)  # [{0,0}, {0,1}, ...]
values = Grid.values(grid)        # [val1, val2, ...]
filtered = Grid.filter(grid, fn x, y, val -> val > 10 end)
```

### Torus - Wrapping 2D Grid

```elixir
# Create torus (same as Grid)
torus = Ximula.Torus.create(width, height, default_value)

# Wrapping behavior
value = Torus.get(torus, -1, 5)   # Wraps to x = width - 1
value = Torus.get(torus, 10, -2)  # Wraps both dimensions
torus = Torus.put(torus, -1, -1, value)  # Wraps to (width-1, height-1)
```

**When to use**:
- **Grid**: Bounded worlds with edges
- **Torus**: Continuous worlds (planets, seamless maps)

## Gatekeeper - Distributed Locking

Provides safe concurrent access to shared resources through exclusive locks.

### Basic Setup

```elixir
# Start with Agent backend
{:ok, agent} = Agent.start_link(fn -> %{} end)
{:ok, gatekeeper} = Ximula.Gatekeeper.Server.start_link(
  context: %{agent: agent},
  max_lock_duration: 5_000  # Auto-release after 5s
)

# Or use Gatekeeper.Agent wrapper
children = [
  Ximula.Gatekeeper.Agent.agent_spec(MyWorld, data: initial_state, name: :world),
  {Ximula.Gatekeeper.Agent, name: :gatekeeper, agent: :world}
]
```

### Read Operations (No Lock)

```elixir
# Direct read (no locking)
value = Gatekeeper.Agent.get(:gatekeeper, fn state ->
  Map.get(state, :my_key)
end)
```

### Lock and Read

```elixir
# Single key
value = Gatekeeper.Agent.lock(:gatekeeper, :key1, fn state ->
  Map.get(state, :key1)
end)

# Multiple keys (locked atomically)
values = Gatekeeper.Agent.lock(:gatekeeper, [:key1, :key2], fn state, key ->
  Map.get(state, key)
end)
```

### Update (Write and Release)

```elixir
# First acquire lock
:ok = Gatekeeper.Agent.request_lock(:gatekeeper, :my_key)

# Then update (releases lock)
:ok = Gatekeeper.Agent.update(:gatekeeper, :my_key, new_value, fn state ->
  Map.put(state, :my_key, new_value)
end)

# Batch update (atomic across multiple keys)
:ok = Gatekeeper.Agent.request_lock(:gatekeeper, [:key1, :key2])
:ok = Gatekeeper.Agent.update_multi(:gatekeeper, 
  [key1: val1, key2: val2], 
  fn state ->
    state
    |> Map.put(:key1, val1)
    |> Map.put(:key2, val2)
  end
)
```

### Lock Lifecycle

```
1. request_lock(key)    → Acquire lock (or queue if held)
2. Do work...           → Lock is held
3. update(key, value)   → Write and release
```

**Critical**: `update/3` expects caller to **already hold the lock**. It will error if lock is not owned.

### Multi-key Locking

```elixir
# Keys are sorted automatically to prevent deadlocks
keys = [:z, :a, :m]
:ok = Gatekeeper.request_lock(gatekeeper, keys)  # Locks in order: :a, :m, :z
```

### Features

- **Exclusive locks**: One process per key at a time
- **Fair queuing**: FIFO for waiting processes
- **Auto-timeout**: Prevents deadlocks (configurable)
- **Process monitoring**: Crashes auto-release locks
- **Independent keys**: High parallelism when keys don't overlap

## Telemetry & Notifications

Configure observability at pipeline, stage, or step level.

### Notification Types

```elixir
:none          # No notifications
:metric        # Telemetry only (duration, counts)
:event         # PubSub only (domain events)
:event_metric  # Both telemetry and PubSub
```

### Configuration Levels

Notifications can be configured at three levels with increasing granularity:

**Pipeline Level** (applies to entire pipeline):
```elixir
pipeline :growth do
  notify(:event_metric)  # All stages emit telemetry + events
end
```

**Stage Level** (two sub-levels):
```elixir
stage :vegetation, :gatekeeper do
  # All entities: Fires once per stage with aggregated results
  notify_all(:event_metric)
  
  # Per entity: Fires once per entity, filtered
  notify_entity(:event_metric, &filter_fn/1)
end
```

**Step Level** (per step per entity, always filtered):
```elixir
step(MyModule, :grow, notify: {:metric, &filter_fn/1})
```

### Stage Notification: `notify_all` vs `notify_entity`

Stages support two independent notification configurations:

```elixir
stage :vegetation, :gatekeeper do
  # notify_all: Stage-level metrics/events
  # Fires ONCE per stage with aggregated data
  # measurements: %{ok: count, failed: count}
  notify_all(:metric)
  
  # notify_entity: Per-entity metrics/events  
  # Fires ONCE per entity that passes filter
  # Useful for tracking specific entities
  notify_entity(:event_metric, fn field -> field.position == {0, 0} end)
  
  step(MyModule, :grow)
end
```

**Use `notify_all` when**:
- You want stage-level performance metrics
- You need aggregate counts (success/failure rates)
- You're monitoring overall stage health

**Use `notify_entity` when**:
- You want to track specific entities through stages
- You need per-entity state changes
- You're building entity-specific UI updates

**Example: Combining Both**:
```elixir
stage :combat, :gatekeeper do
  notify_all(:metric)  # Track: "Combat stage took 50ms, 100 entities, 2 deaths"
  
  notify_entity(:event, fn change ->  # Track: "Player X died at position Y"
    Change.get(change, :health) <= 0
  end)
  
  step(Combat, :resolve_damage)
end
```

### Filter Functions

```elixir
# Filter on Change struct (for steps)
def notify_filter(%Change{} = change) do
  Change.get(change, :position) == {0, 0}
end

# Filter on entity data (for stages)
def notify_filter(%{position: position}) do
  position == {0, 0}
end
```

### Telemetry Events

Ximula emits telemetry events at different levels of execution. All events follow the pattern `[:ximula, :sim, ...]`.

**Event Reference**:

```elixir
# Queue level (entire queue execution)
[:ximula, :sim, :queue, :start]
[:ximula, :sim, :queue, :stop]
# measurements: %{duration: native_time, monotonic_time: integer}
# metadata: %{name: atom, interval: integer}

# Pipeline level (entire pipeline execution)
[:ximula, :sim, :pipeline, :start]
[:ximula, :sim, :pipeline, :stop]
# measurements: %{duration: native_time, monotonic_time: integer}
# metadata: %{name: string}

# Stage level (all entities in stage - aggregate)
[:ximula, :sim, :pipeline, :stage, :start]
[:ximula, :sim, :pipeline, :stage, :stop]
# measurements: %{duration: native_time, ok: integer, failed: integer}
# metadata: %{stage_name: string}

# Entity level (per entity in stage - filtered)
[:ximula, :sim, :pipeline, :stage, :entity, :start]
[:ximula, :sim, :pipeline, :stage, :entity, :stop]
# measurements: %{duration: native_time}
# metadata: %{stage_name: string}

# Step level (per step per entity - filtered)
[:ximula, :sim, :pipeline, :stage, :step, :start]
[:ximula, :sim, :pipeline, :stage, :step, :stop]
# measurements: %{duration: native_time}
# metadata: %{change: %Change{}, module: atom, function: atom}
```

**Attach handlers**:

```elixir
# Attach handlers
:telemetry.attach_many(
  "my-handler",
  [
    [:ximula, :sim, :queue, :start],
    [:ximula, :sim, :queue, :stop],
    [:ximula, :sim, :pipeline, :start],
    [:ximula, :sim, :pipeline, :stop],
    [:ximula, :sim, :pipeline, :stage, :start],
    [:ximula, :sim, :pipeline, :stage, :stop],
    [:ximula, :sim, :pipeline, :stage, :entity, :start],
    [:ximula, :sim, :pipeline, :stage, :entity, :stop],
    [:ximula, :sim, :pipeline, :stage, :step, :start],
    [:ximula, :sim, :pipeline, :stage, :step, :stop]
  ],
  &MyModule.handle_telemetry/4,
  %{}
)

def handle_telemetry(event, measurements, metadata, config) do
  duration = measurements.duration  # in native time units
  duration_ms = System.convert_time_unit(duration, :native, :millisecond)
  
  # Process metrics...
  IO.puts("Event: #{inspect(event)}")
  IO.puts("Duration: #{duration_ms}ms")
  IO.puts("Metadata: #{inspect(metadata)}")
end
```

**Converting Time Units**:

```elixir
# Telemetry uses native time units for precision
native_duration = measurements.duration

# Convert to common units
microseconds = System.convert_time_unit(native_duration, :native, :microsecond)
milliseconds = System.convert_time_unit(native_duration, :native, :millisecond)
seconds = System.convert_time_unit(native_duration, :native, :second)
```

### PubSub Events

PubSub events are emitted based on notification configuration and carry domain-specific payloads.

**Topic Structure**:
```
sim:pipeline:#{pipeline_name}                    # Pipeline completed
sim:pipeline:stage:#{stage_name}                 # Stage completed (all entities)
sim:pipeline:stage:#{stage_name}:entity          # Entity completed in stage
sim:pipeline:stage:entity:step                   # Step completed (rarely used)
```

**Event Payloads**:

```elixir
# Pipeline completed
{:pipeline_completed, %{
  pipeline_name: "growth",
  result: final_data
}}

# Stage completed (aggregate)
{:stage_completed, %{
  stage_name: "vegetation",
  result: %{ok: [entity1, entity2], exit: []}
}}

# Entity completed in stage
{:entity_stage_completed, %{
  stage_name: "vegetation", 
  result: updated_entity_data
}}

# Step completed
{:step_completed, %{
  step_module: VegetationSim,
  step_function: :grow_crops,
  result: %Change{}
}}
```

**Subscribe to events**:

```elixir
# Subscribe to events
Phoenix.PubSub.subscribe(:my_pubsub, "sim:pipeline:growth")
Phoenix.PubSub.subscribe(:my_pubsub, "sim:pipeline:stage:vegetation")
Phoenix.PubSub.subscribe(:my_pubsub, "sim:pipeline:stage:vegetation:entity")

# Receive events
receive do
  {:pipeline_completed, %{pipeline_name: name, result: result}} ->
    IO.inspect("Pipeline #{name} completed with result: #{inspect(result)}")
    
  {:stage_completed, %{stage_name: name, result: %{ok: ok, exit: failed}}} ->
    IO.inspect("Stage #{name}: #{length(ok)} succeeded, #{length(failed)} failed")
    
  {:entity_stage_completed, %{stage_name: name, result: entity}} ->
    IO.inspect("Entity completed in stage #{name}: #{inspect(entity)}")
    
  {:step_completed, %{step_module: mod, step_function: fun, result: result}} ->
    IO.inspect("Step #{mod}.#{fun} completed")
end
```

**LiveView Integration Example**:

```elixir
defmodule MyAppWeb.SimulationLive do
  use MyAppWeb, :live_view
  
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to entity updates for UI
      Phoenix.PubSub.subscribe(:my_pubsub, "sim:pipeline:stage:vegetation:entity")
    end
    
    {:ok, assign(socket, entities: [])}
  end
  
  def handle_info({:entity_stage_completed, %{result: entity}}, socket) do
    # Update UI with entity changes
    entities = [entity | socket.assigns.entities] |> Enum.take(100)
    {:noreply, assign(socket, entities: entities)}
  end
end
```

## Execution Flow

```
Loop GenServer (every interval)
  └─> Queue Task (supervised)
      └─> Filter data (queue function)
          └─> Pipeline.execute(pipeline, filtered_data)
              └─> Stage 1
                  ├─> Adapter.run_stage (coordinates execution)
                  ├─> TaskRunner.sim (parallel execution)
                  │   ├─> Task 1: read → steps → write
                  │   ├─> Task 2: read → steps → write
                  │   └─> Task N: read → steps → write
                  └─> Collect results
              └─> Stage 2
                  └─> (same pattern)
              └─> Return final result
```

### Timing Considerations

```elixir
queue :my_queue, 1000 do  # Runs every 1000ms
  run_pipeline(:my_pipeline, supervisor: MySupervisor) do
    get_entities()
  end
end
```

**Warning**: If pipeline execution takes longer than the interval, the next tick is skipped with a warning:

```
Queue my_queue took 1500 μs, but has an interval of 1000 μs
Queue is too slow! Previous task didn't return yet. Skipping this tick!
```

**Best practice**: Set intervals 2-3x longer than expected execution time.

## Complete Example

```elixir
defmodule CropSimulation do
  use Ximula.Sim
  
  alias Ximula.{Grid, Torus}
  alias Ximula.Gatekeeper.Agent, as: Gatekeeper
  alias Ximula.Sim.Change
  
  # ─── Setup ───
  
  def start do
    children = [
      Gatekeeper.agent_spec(__MODULE__, data: nil, name: :world),
      {Gatekeeper, name: :gatekeeper, agent: :world},
      {Phoenix.PubSub, name: :pubsub},
      {Task.Supervisor, name: :loop_supervisor},
      {Task.Supervisor, name: :runner_supervisor},
      {Ximula.Sim.Loop, name: :sim_loop, supervisor: :loop_supervisor}
    ]
    Supervisor.start_link(children, strategy: :rest_for_one)
  end
  
  def init_world(size) do
    world = Torus.create(size, size, fn _x, _y ->
      %{
        crops: 10,
        water: 100,
        soil_quality: :random.uniform(100)
      }
    end)
    
    Gatekeeper.direct_set(:gatekeeper, fn _ -> world end)
  end
  
  # ─── DSL ───
  
  simulation do
    default(gatekeeper: :gatekeeper, pubsub: :pubsub)
    
    pipeline :farming do
      notify(:event_metric)
      
      stage :crop_growth, :gatekeeper do
        notify_all(:metric)
        read_fun(&CropSimulation.read_field/2)
        write_fun(&CropSimulation.write_field/2)
        step(CropSimulation, :grow_crops)
        step(CropSimulation, :consume_water)
      end
      
      stage :weather, :single do
        step(CropSimulation, :apply_rain)
      end
    end
    
    queue :daily, 1000 do
      run_pipeline(:farming, supervisor: :runner_supervisor) do
        CropSimulation.all_positions()
      end
    end
  end
  
  # ─── Gatekeeper Functions ───
  
  def all_positions do
    Gatekeeper.get(:gatekeeper, &Grid.positions/1)
  end
  
  def read_field(position, gatekeeper) do
    field = Gatekeeper.lock(gatekeeper, position, fn _key ->
      Agent.get(:world, &Grid.get(&1, position))
    end)
    Map.put(field, :position, position)
  end
  
  def write_field(%{position: position} = field, gatekeeper) do
    Gatekeeper.update(gatekeeper, position, fn _data, context ->
      Agent.update(context.agent, &Grid.put(&1, position, 
        Map.delete(field, :position)))
    end)
  end
  
  # ─── Simulation Steps ───
  
  def grow_crops(%Change{} = change) do
    water = Change.get(change, :water)
    soil = Change.get(change, :soil_quality)
    
    growth_rate = calculate_growth(water, soil)
    
    change
    |> Change.change_by(:crops, growth_rate)
  end
  
  def consume_water(%Change{} = change) do
    crops = Change.get(change, :crops)
    consumption = crops * 0.1
    
    Change.change_by(change, :water, -consumption)
  end
  
  def apply_rain(%Change{} = change) do
    # Single stage operates on aggregated data
    rain_amount = :random.uniform(20)
    Change.change_by(change, :global_water, rain_amount)
  end
  
  defp calculate_growth(water, soil) do
    cond do
      water < 20 -> 0
      water < 50 -> soil * 0.01
      true -> soil * 0.02
    end
  end
end

# Run simulation
CropSimulation.start()
CropSimulation.init_world(10)

queues = CropSimulation.build_queues()
Ximula.Sim.Loop.add_queues(:sim_loop, queues)
Ximula.Sim.Loop.start_sim(:sim_loop)

# Check results after some time
:timer.sleep(5000)
field = Gatekeeper.Agent.lock(:gatekeeper, {0, 0}, fn state ->
  Grid.get(state, {0, 0})
end)
IO.inspect(field)
```

## Best Practices

### 1. Keep Steps Pure

```elixir
# ✅ Good - pure function
def grow_crops(%Change{} = change) do
  water = Change.get(change, :water)
  Change.change_by(change, :crops, calculate_growth(water))
end

# ❌ Bad - side effects
def grow_crops(%Change{} = change) do
  Logger.info("Growing crops")  # Side effect!
  send_notification()            # Side effect!
  Change.change_by(change, :crops, 1)
end
```

### 2. Use Appropriate Adapters

```elixir
# Gatekeeper: When entities interact
stage :combat, :gatekeeper do
  step(Combat, :attack_nearby_enemies)
end

# Grid: When cells are independent
stage :terrain, :grid do
  step(Terrain, :erode)
end

# Single: When operating on aggregated state
stage :world, :single do
  step(World, :advance_season)
end
```

### 3. Handle Missing Data

```elixir
def process_entity(%Change{} = change) do
  # Safely handle missing keys
  health = Change.get(change, :health) || 100
  
  if health > 0 do
    Change.change_by(change, :health, -1)
  else
    change
  end
end
```

### 4. Use `:no_change` for Performance

```elixir
# ✅ Good - explicit no-op
def grow_crops(%Change{} = change) do
  water = Change.get(change, :water)
  
  if water > 10 do
    change |> Change.change_by(:vegetation, 1)
  else
    :no_change  # Filtered out by TaskRunner
  end
end

# ❌ Less efficient - creates unnecessary change struct
def grow_crops(%Change{} = change) do
  water = Change.get(change, :water)
  
  if water > 10 do
    change |> Change.change_by(:vegetation, 1)
  else
    change  # Still processes through write_fun
  end
end
```

### 5. Use Metadata for Routing

```elixir
# Add position as metadata (not persisted)
def read_field(position, gatekeeper) do
  field = Gatekeeper.lock(gatekeeper, position, &get_data/2)
  Map.put(field, :position, position)  # Routing metadata
end

# Remove before persisting
def write_field(%{position: position} = field, gatekeeper) do
  clean_field = Map.delete(field, :position)
  Gatekeeper.update(gatekeeper, position, &save_data/3)
end
```

### 6. Set Realistic Intervals

```elixir
# ❌ Bad - too frequent
queue :fast, 10 do  # 10ms interval
  run_pipeline(:heavy_computation, ...)  # Takes 50ms
end

# ✅ Good - appropriate buffer
queue :reasonable, 200 do  # 200ms interval
  run_pipeline(:heavy_computation, ...)  # Takes 50ms, 4x buffer
end
```

### 7. Use Filters for Selective Notification

```elixir
# Only notify for significant changes
def notify_filter(%Change{} = change) do
  health = Change.get(change, :health)
  health <= 0  # Only notify on death
end

stage :combat, :gatekeeper do
  notify_entity(:event, &notify_filter/1)
  step(Combat, :take_damage)
end
```

## Performance Considerations

### Parallelism

- **Grid adapter**: All cells process in parallel (high throughput)
- **Gatekeeper adapter**: Keys locked independently (parallelism with safety)
- **Single adapter**: No parallelism (use for coordination only)

### Lock Contention

```elixir
# Low contention - many independent keys
positions = [{0,0}, {1,1}, {2,2}, {3,3}]  # 4 separate locks

# High contention - few keys with many accesses
positions = [:global_state, :global_state, :global_state]  # All wait on 1 lock
```

**Optimization**: Use fine-grained keys (per-entity) rather than coarse keys (global state).

### Task Overhead

```elixir
# More tasks = more overhead
TaskRunner.sim(
  1..10000,
  simulation,
  supervisor,
  max_concurrency: 100  # Limit concurrent tasks
)
```

**Rule of thumb**: Keep tasks > 1ms execution time. For very fast operations, batch entities.

### Memory

- `%Change{}` structs are created per entity per stage
- Grids are copied when modified (immutable)
- Keep entity data compact

## Troubleshooting

### "locks must be owned by the caller"

```elixir
# ❌ Wrong - calling update without lock
def write_field(field, gatekeeper) do
  Gatekeeper.update(gatekeeper, :key, fn ... end)
end

# ✅ Correct - lock acquired in read_fun, held until update
def read_field(key, gatekeeper) do
  Gatekeeper.lock(gatekeeper, key, fn ... end)  # Acquires and holds
end

def write_field(field, gatekeeper) do
  Gatekeeper.update(gatekeeper, :key, fn ... end)  # Releases
end
```

### "Queue is too slow"

Increase interval or optimize pipeline:

```elixir
# Option 1: Increase interval
queue :my_queue, 2000 do  # Was 1000, now 2000
  run_pipeline(:slow_pipeline, ...)
end

# Option 2: Add max_concurrency
queue :my_queue, 1000 do
  run_pipeline(:pipeline, supervisor: MySup, max_concurrency: 50) do
    # Limits parallel tasks
  end
end

# Option 3: Split into multiple queues
queue :fast_ops, 500 do
  run_pipeline(:quick_pipeline, ...)
end

queue :slow_ops, 2000 do
  run_pipeline(:heavy_pipeline, ...)
end
```

### Pipeline Not Found

```elixir
# ❌ Wrong - pipeline not defined
queue :my_queue do
  run_pipeline(:undefined_pipeline, ...)  # Error at compile time
end

# ✅ Correct - define pipeline first
pipeline :my_pipeline do
  stage :my_stage, :single do
    step(MyModule, :my_step)
  end
end

queue :my_queue do
  run_pipeline(:my_pipeline, ...)
end
```

### Grid Out of Bounds

```elixir
# Grid returns error tuple for out of bounds
{:error, reason} = Grid.get(grid, -1, 5)

# Torus wraps automatically
value = Torus.get(torus, -1, 5)  # Returns wrapped value
```

## Advanced Patterns

### Custom Adapters

Create your own adapter by implementing the `Ximula.Sim.StageAdapter` behaviour:
```elixir
defmodule MyCustomAdapter do
  @moduledoc """
  Custom adapter for specialized entity processing.
  Implements batching and retry logic.
  """
  
  @behaviour Ximula.Sim.StageAdapter
  
  alias Ximula.Sim.Pipeline
  
  @impl true
  def run_stage(stage, %{data: data, opts: opts}) do
    data
    |> batch_entities(size: 100)
    |> Pipeline.run_tasks({Pipeline, :execute_steps}, stage, opts)
    |> handle_results()
  end
  
  defp batch_entities(data, size: size) do
    Enum.chunk_every(data, size)
  end
  
  defp handle_results({:ok, results}), do: {:ok, List.flatten(results)}
  defp handle_results({:error, _} = error), do: error
end

# Use in simulation
simulation do
  pipeline :batched do
    stage :processing, MyCustomAdapter do
      step(MyModule, :process)
    end
  end
end
```

**Behaviour Contract**:

The `Ximula.Sim.StageAdapter` behaviour requires:
```elixir
@callback run_stage(stage, input) :: {:ok, term()} | {:error, term()}
  when stage: %{
    adapter: module(),
    steps: [step()],
    notify: notify_config(),
    name: String.t()
  },
  input: %{
    data: term(),
    opts: keyword()
  }
```

**Implementation Requirements**:

1. **Accept stage map** with:
   - `adapter`: Your module
   - `steps`: List of step definitions
   - `notify`: Notification configuration
   - `name`: Stage identifier
   - Optional: `read_fun`, `write_fun`, `gatekeeper` (for custom needs)

2. **Accept context map** with:
   - `data`: Entities/data to process
   - `opts`: Options (supervisor, gatekeeper, etc.)

3. **Return**:
   - `{:ok, result}` on success
   - `{:error, reasons}` on failure

4. **Responsibilities**:
   - Transform input data if needed
   - Call `Pipeline.run_tasks/4` for parallel execution (or implement custom parallelism)
   - Handle and transform results
   - Respect notification configuration in `stage`

**Built-in Adapter Reference**:

```elixir
# Single - Direct execution, returns first result
StageAdapter.Single.run_stage(stage, context)

# Grid - Maps grid positions, applies changes back
StageAdapter.Grid.run_stage(stage, %{data: grid, opts: opts})

# Gatekeeper - Locks keys, reads, processes, writes
StageAdapter.Gatekeeper.run_stage(stage, %{data: keys, opts: opts})
```

**Queue Replacement**:

Adding a queue with an existing name replaces the old queue:

```elixir
# First queue
queue1 = %Queue{name: :normal, interval: 1000, func: fn -> ... end}
Loop.add_queue(:loop, queue1)

# Replaces first queue (same name)
queue2 = %Queue{name: :normal, interval: 500, func: fn -> ... end}
Loop.add_queue(:loop, queue2)

# Only queue2 exists now
```

## FAQ

### Q: When should I use Ximula vs GenStage/Flow?

**Use Ximula when**:
- Discrete event simulations (turn-based, tick-based)
- Need coordinated entity interactions with locking
- Spatial/grid-based simulations
- Want observable simulation pipelines with telemetry

**Use GenStage/Flow when**:
- Continuous data processing pipelines
- Need backpressure mechanisms
- Processing unbounded streams
- Don't need entity coordination

### Q: How do I handle entity interactions (combat, trade)?

For interactions between entities, you need to lock both entities. There are two approaches:

**Approach 1: Lock Both Keys in Queue Filter**

```elixir
# Queue provides BOTH entities' keys
queue :combat do
  run_pipeline(:combat, supervisor: MySup) do
    # Return pairs of interacting entities
    get_combat_pairs()  # [{attacker_key, target_key}, ...]
  end
end

# read_fun locks and reads both
def read_combat_pair({attacker_key, target_key}, gatekeeper) do
  # Lock both keys (sorted to prevent deadlocks)
  keys = Enum.sort([attacker_key, target_key])
  
  data = Gatekeeper.lock(gatekeeper, keys, fn _keys ->
    attacker = Agent.get(:world, &get_entity(&1, attacker_key))
    target = Agent.get(:world, &get_entity(&1, target_key))
    
    %{
      attacker: attacker,
      target: target,
      keys: {attacker_key, target_key}
    }
  end)
  
  data
end

# Step processes both entities
def resolve_combat(%Change{} = change) do
  attacker = Change.get(change, :attacker)
  target = Change.get(change, :target)
  
  damage = calculate_damage(attacker, target)
  
  change
  |> Change.change_by([:target, :health], -damage)
  |> Change.change_by([:attacker, :stamina], -5)
end

# write_fun updates both
def write_combat_result(%{attacker: attacker, target: target, keys: {a_key, t_key}}, gatekeeper) do
  Gatekeeper.update_multi(gatekeeper, 
    [{a_key, attacker}, {t_key, target}],
    fn _data, context ->
      Agent.update(context.agent, fn world ->
        world
        |> update_entity(a_key, attacker)
        |> update_entity(t_key, target)
      end)
    end
  )
end
```

**Approach 2: Single-Entity View with References**

```elixir
# Each entity processes independently but reads neighbor data
def read_entity_with_neighbors(key, gatekeeper) do
  entity = Gatekeeper.lock(gatekeeper, key, fn _key ->
    Agent.get(:world, &get_entity(&1, key))
  end)
  
  # Read nearby entities (no lock needed, read-only)
  neighbors = Gatekeeper.get(gatekeeper, fn world ->
    get_neighbors(world, entity.position)
  end)
  
  Map.put(entity, :neighbors, neighbors)
end

# Step can see neighbors but only modify self
def attack_nearby(%Change{} = change) do
  neighbors = Change.get(change, :neighbors)
  targets = Enum.filter(neighbors, &is_enemy?/1)
  
  if Enum.any?(targets) do
    # Mark attack intent (resolved in next stage)
    change |> Change.set(:attack_target, List.first(targets).id)
  else
    :no_change
  end
end
```

**Important**: Multi-key locking in Gatekeeper always sorts keys to prevent deadlocks. The order you provide doesn't matter - they'll be locked in sorted order.

### Q: Can steps communicate with each other?

Steps are isolated but can read prior step changes via `Change.get/2`:

```elixir
# Step 1 modifies health
def take_damage(%Change{} = change) do
  Change.change_by(change, :health, -10)
end

# Step 2 reads the accumulated change
def check_death(%Change{} = change) do
  current_health = Change.get(change, :health)  # Includes step 1 change
  
  if current_health <= 0 do
    Change.set(change, :status, :dead)
  else
    :no_change
  end
end
```

## Summary

**Ximula provides**:
- ✅ Clean separation: scheduling, coordination, logic
- ✅ Safe concurrency through locking or independence
- ✅ Composable pure functions (steps)
- ✅ Observable through telemetry and events
- ✅ Flexible execution strategies (adapters)
- ✅ Declarative DSL for simulation definition
- ✅ Performance optimizations (`:no_change`, filters)

**Key Features**:
- **DSL**: Declarative `simulation do` blocks with compile-time validation
- **Three Adapters**: Single (sequential), Grid (parallel), Gatekeeper (locked)
- **Change Pattern**: Immutable reads + accumulated writes solve step ordering
- **Dynamic Filtering**: Queue filters run each tick, no static partitions
- **Two-Level Observability**: Telemetry (metrics) + PubSub (events)
- **Custom Adapters**: Implement `run_stage/2` protocol for specialized processing
- **Nested Keys**: Support for complex entity structures via list keys

**Use Ximula when you need**:
- Discrete event simulations (turn-based, tick-based)
- Parallel entity processing with coordination
- Spatial simulations (grids, terrain, agents)
- Observable simulation pipelines with metrics
- Declarative simulation configuration

**Not ideal for**:
- Real-time continuous simulations (use GenStage/Flow)
- Extremely high frequency (sub-millisecond ticks)
- Simulations requiring guaranteed ordering within a tick
- Scenarios where browser storage is needed (artifacts run in restricted environment)
