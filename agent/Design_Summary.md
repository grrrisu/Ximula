# Ximula.Sim - Design Summary

## Core Concept
A composable, pipeline-based simulation library for Elixir that separates simulation logic (pure functions) from execution strategy (parallel/sequential), state management (Gatekeeper with locking), and event handling (declarative side effects via Telemetry and PubSub).

---

## Architecture Overview

```
┌─────────────────────┐
│  Loop (GenServer)   │  ← Orchestration: queues, timers, tasks
│  - queues           │     Ephemeral (can crash/restart)
│  - timers/tasks     │
│  - supervisor ref   │
└──────────┬──────────┘
           │
           ├────────────────────┬─────────────────────┐
           │                    │                     │
┌──────────▼──────────┐  ┌──────▼───────────┐  ┌──────▼───────┐
│ Phoenix.PubSub      │  │ Gatekeeper       │  │ Task.Sup     │
│ (event broadcast)   │  │ (Agent wrapper)  │  │ (loop tasks) │
└─────────────────────┘  │ - world grid     │  └──────────────┘
                         │ - locks          │
                         │ - tick counter   │  ┌──────────────┐
                         └──────────────────┘  │ Task.Sup     │
                                               │ (sim tasks)  │
                                               └──────────────┘
```

**Key Design**: 
- **Gatekeeper** holds world data (persistent, survives Loop crashes)
- **Loop** holds orchestration state (queues, timers - ephemeral)
- **Queue.func** contains filtering logic (runs fresh each tick)

---

## Three Levels of Execution

### Queue / Loop (Timing & Orchestration)
* **Purpose**: Schedules when to run, filters what to process
* **Properties**: name, interval, func (filter + pipeline execution), timer, task
* **Implementation**: GenServer manages queue lifecycle, timers, and tasks
* **Execution**: Each queue runs its `func()` in supervised task
* **API**: `Loop.add_queue(loop, queue)`, `Loop.start_sim(loop)`
* **Example**: Queue runs every 100ms, filters urgent fields, executes pipeline
* **State**: Ephemeral (queues rebuilt on restart with filter logic intact)

**Queue Structure:**
```elixir
%Queue{
  name: :urgent,
  interval: 100,
  func: fn ->
    # Filter positions from Gatekeeper
    positions = Gatekeeper.get(gatekeeper, fn grid ->
      Grid.positions(grid)
      |> Enum.filter(fn pos ->
        Grid.get(grid, pos).urgent == true
      end)
    end)
    
    # Execute pipeline on filtered positions
    Pipeline.execute(pipeline, %{
      data: positions,
      opts: [gatekeeper: :gatekeeper, ...]
    })
  end,
  timer: nil,   # Set at runtime
  task: nil     # Set at runtime
}
```

**Queue.add_pipeline Helper:**
```elixir
# Convenience function that wraps Pipeline.execute in queue.func
Queue.add_pipeline(%Queue{}, pipeline, %{data: positions, opts: [...]})
# Returns: %Queue{func: fn -> Pipeline.execute(pipeline, ...) end}
```

### Pipeline / Stage (Coordination & Execution Strategy)
* **Purpose**: Defines what runs and how (sequential stages)
* **Properties**: stages (list), name, notify config, pubsub
* **Stage Properties**: adapter, steps (list), notify config, read_fun, write_fun, gatekeeper
* **Execution**: 
  - Stages run sequentially via `Enum.reduce`
  - Each stage calls its adapter's `run_stage/2`
  - Adapters call `Pipeline.run_tasks` → `TaskRunner.sim` for parallel execution
  - Gatekeeper adapter locks positions, reads via `read_fun`, writes via `write_fun`
* **API**: `Pipeline.execute(pipeline, %{data: ..., opts: []})`
* **Example**: Stage 1: grow_crops → Stage 2: consume_food
* **State**: Static (built once as data structure)

**Pipeline Structure:**
```elixir
%{
  stages: [
    %{
      adapter: StageAdapter.Gatekeeper,
      steps: [
        %{module: VegetationSim, function: :grow, notify: {:metric, filter}, pubsub: ...}
      ],
      notify: %{all: :metric, entity: {:event_metric, filter}},
      gatekeeper: :gatekeeper,
      read_fun: &get_field/2,
      write_fun: &put_field/2,
      name: "vegetation",
      pubsub: :my_pub_sub
    }
  ],
  name: "world_pipeline",
  notify: :event_metric,
  pubsub: :my_pub_sub
}
```

**Pipeline Builder API:**
```elixir
Pipeline.new_pipeline(notify: :metric, name: "sim", pubsub: :my_pub_sub)
|> Pipeline.add_stage(
  adapter: GatekeeperAdapter,
  notify: %{all: :metric, entity: {:event_metric, filter}},
  name: "stage_name",
  gatekeeper: :gatekeeper,
  read_fun: &read/2,
  write_fun: &write/2
)
|> Pipeline.add_step(Module, :function, notify: {:metric, filter})
```

### Simulation / Step (Pure Logic)
* **Purpose**: Implements game/simulation rules
* **Properties**: Pure functions, no side effects
* **Signature**: `def step(%Change{data, changes}, opts \\ [])`
* **Returns**: `%Change{changes: updated}`
* **API**: Pattern-matched functions that transform Change structs
* **Example**: Calculate crop growth based on water + soil
* **Events**: Emit telemetry/pubsub via notify configuration

**Change Struct Pattern:**
```elixir
%Change{
  data: %{vegetation: 100, water: 50},      # Original (tick N-1)
  changes: %{vegetation: 1, water: -1}      # Accumulated changes
}

# Steps read current values and accumulate changes
def grow_crops(%Change{} = change) do
  current_vegetation = Change.get(change, :vegetation)  # 101
  current_water = Change.get(change, :water)            # 49
  
  if current_water > 0 do
    change
    |> Change.change_by(:vegetation, 1)
    |> Change.change_by(:water, -1)
  else
    change
  end
end

# At end of stage, adapter calls Change.reduce/1
# Result: %{vegetation: 102, water: 48}
```

---

## Execution Flow

**Complete tick execution:**

1. **Timer Fires** → `Loop` receives `{:tick, queue}`
2. **Loop Executes** → `Queue.execute(queue, sim_args)`
3. **Queue.func Runs** → 
   - Filters positions from Gatekeeper
   - Calls `Pipeline.execute(pipeline, %{data: positions, opts: [...]})`
4. **Pipeline Executes Stages** → `Enum.reduce(stages, result, &execute_stage/2)`
5. **Each Stage** → `adapter.run_stage(stage, %{data: positions, opts: opts})`
6. **Adapter (Gatekeeper)** → 
   - Calls `Pipeline.run_tasks(positions, {__MODULE__, :run_entity}, stage, opts)`
   - Which calls `TaskRunner.sim(positions, {Module, :run_entity, [stage]}, supervisor, opts)`
7. **TaskRunner** → Spawns parallel tasks via `Task.Supervisor.async_stream_nolink`
8. **Each Entity Task** → 
   - `run_entity(position, stage)` locks and reads via `read_fun`
   - Calls `Pipeline.execute_steps(data, stage)`
   - Returns result
9. **Execute Steps** → `Enum.reduce(steps, %Change{data: data}, &execute_step/2)`
10. **Each Step** → `apply(module, function, [change])`
11. **Collect Results** → TaskRunner groups by `:ok` and `:exit`
12. **Write Back** → Each entity result written via `write_fun.(result, gatekeeper)`
13. **Next Tick** → Loop schedules next timer

```
Loop (timer) 
  └─> Queue.execute()
       └─> Queue.func() [filter + Pipeline.execute]
            └─> Pipeline.execute()
                 └─> Stage 1: adapter.run_stage()
                      └─> Pipeline.run_tasks()
                           └─> TaskRunner.sim()
                                └─> async_stream_nolink [parallel]
                                     ├─> Entity 1: run_entity → execute_steps → step functions
                                     ├─> Entity 2: run_entity → execute_steps → step functions
                                     └─> Entity N: run_entity → execute_steps → step functions
                                └─> Collect {:ok, results}
                      └─> Results collected
                 └─> Stage 2: adapter.run_stage()
                      └─> [repeat...]
```

---

## Key Design Decisions

### 1. State Management & Data Ownership

**Gatekeeper (Persistent - World Data)**
```elixir
# Ximula.Gatekeeper.Agent wraps an Agent
Gatekeeper.agent_spec(MyWorld, data: nil, name: :world)
{Ximula.Gatekeeper.Agent, name: :gatekeeper, agent: :world}

# Holds Grid structure
%Grid{
  width: 100,
  height: 100,
  fields: %{
    {0, 0} => %{terrain: :ocean, vegetation: 100, urgent: false},
    {3, 5} => %{terrain: :settlement, vegetation: 150, urgent: true}
  }
}

# Also tracks tick counter (optional)
```

**Why Gatekeeper**: 
- Provides locking mechanism for concurrent access
- Single source of truth for world state
- Survives Loop crashes (data persists)
- Can be persisted/restored independently

**Loop (Ephemeral - Orchestration)**
```elixir
%{
  running: true,
  queues: [%Queue{...}, %Queue{...}],
  supervisor: :loop_task_supervisor,
  sim_args: []  # Global args passed to all queues
}
```

**Why Loop is ephemeral**: 
- Queues can be rebuilt on restart (stateless orchestration)
- Timer/task references are runtime-only
- Filter logic is in queue.func (declarative, not stateful)

**Benefits:**
- Loop crashes don't lose world data
- No partition management complexity
- Field state naturally determines processing via filters
- Simple recovery: restart Loop, rebuild queues, resume

---

### 2. Dynamic Queue Filtering

**Queue filters positions each tick via func:**

```elixir
# Queue determines what to process
%Queue{
  name: :urgent,
  interval: 100,
  func: fn ->
    # 1. Filter fresh each tick
    positions = Gatekeeper.get(:gatekeeper, fn grid ->
      Grid.positions(grid)
      |> Enum.filter(fn pos ->
        field = Grid.get(grid, pos)
        field.urgent == true
      end)
    end)
    
    # 2. Execute pipeline on filtered positions
    Pipeline.execute(pipeline, %{
      data: positions,
      opts: [gatekeeper: :gatekeeper, supervisor: :task_runner_supervisor]
    })
  end
}

# Alternative: use Queue.add_pipeline helper
Queue.add_pipeline(
  %Queue{name: :urgent, interval: 100},
  pipeline,
  %{
    data: positions(:gatekeeper),  # Static or dynamic
    opts: [gatekeeper: :gatekeeper, ...]
  }
)
```

**How field state affects queues:**

```elixir
# Simulation step changes field state
def check_resources(%Change{} = change) do
  resources = Change.get(change, :resources)
  
  if resources < 10 do
    change
    |> Change.set(:urgent, true)   # Next tick: urgent queue picks it up
    |> Change.set(:alert, "Low resources!")
  else
    change
    |> Change.set(:urgent, false)  # Next tick: normal queue skips it
  end
end
```

**Benefits:**
- ✅ No static partitions to maintain
- ✅ No migration coordination needed
- ✅ Filter logic is in queue (where it belongs)
- ✅ Field state naturally determines processing
- ✅ Simple and flexible (any filter logic)
- ✅ Survives Loop crashes (queues rebuilt with filter logic)

**Performance consideration:**

```elixir
# For large grids, optimize filter
%Queue{
  name: :urgent,
  interval: 100,
  func: fn ->
    # Option 1: Track urgent positions in Gatekeeper
    # Option 2: Use ETS index if available
    # Option 3: Short-circuit if no urgent fields exist
    
    has_urgent = Gatekeeper.get(:gatekeeper, &Grid.any?(&1, fn {_pos, field} -> field.urgent end))
    
    if has_urgent do
      positions = Gatekeeper.get(:gatekeeper, fn grid ->
        Grid.positions(grid)
        |> Enum.filter(&Grid.get(grid, &1).urgent)
      end)
      Pipeline.execute(pipeline, %{data: positions, opts: [...]})
    else
      {:ok, []}  # Skip processing
    end
  end
}
```

---

### 3. Three Stage Adapters

**Adapters implement the protocol:**
```elixir
# Protocol: adapter.run_stage(stage, %{data: input, opts: opts})
# Returns: {:ok, result} | {:error, reasons}
```

#### StageAdapter.Single
**Use for**: Single entity, aggregated state, sequential processing

```elixir
def run_stage(stage, %{data: data, opts: opts}) do
  data
  |> Pipeline.run_tasks({Pipeline, :execute_steps}, stage, opts)
  |> reduce_data()
end

def reduce_data({:ok, results}), do: {:ok, List.first(results)}
```

**Example**: World-level calculations, global counters, single settlement

#### StageAdapter.Grid
**Use for**: Spatial 2D grid, independent entities, no locking needed

```elixir
def run_stage(stage, %{data: grid, opts: opts}) do
  grid
  |> get_fields()  # Map to %{position: {x,y}, field: data}
  |> Pipeline.run_tasks({Pipeline, :execute_steps}, stage, opts)
  |> reduce_grid(grid)
end

def reduce_grid({:ok, results}, grid) do
  changes = Enum.map(results, fn %{position: pos, field: field} -> {pos, field} end)
  {:ok, Grid.apply_changes(grid, changes)}
end
```

**Example**: Terrain simulation, vegetation growth, weather patterns

#### StageAdapter.Gatekeeper
**Use for**: Locked entities, coordinated updates, atomic operations

```elixir
def run_stage(stage, %{data: keys, opts: opts}) do
  keys
  |> Pipeline.run_tasks({__MODULE__, :run_entity}, stage, opts)
end

def run_entity(key, %{gatekeeper: gatekeeper, read_fun: read_fun, write_fun: write_fun} = stage) do
  key
  |> read_fun.(gatekeeper)           # Lock and read
  |> Pipeline.execute_steps(stage)   # Run simulation steps
  |> write_fun.(gatekeeper)          # Write back
end
```

**Example**: Population movement, resource trading, combat, migration

**Required opts for Gatekeeper adapter:**
- `:gatekeeper` - Process name/PID
- `:read_fun` - `(key, gatekeeper) -> entity`
- `:write_fun` - `(entity, gatekeeper) -> key`

---

### 4. Separation of Concerns

**Simulation Layer (Pure)**
- No processes, no side effects, no direct state access
- Pattern-matched functions: `def step(%Change{data, changes})`
- Returns: `%Change{changes: updated}`
- Reads via `Change.get/2`, writes via `Change.change_by/3` or `Change.set/3`

**Execution Layer (Stateful)**
- **Loop**: Orchestration, queues, timers, task supervision
- **TaskRunner**: Parallel execution via `Task.Supervisor.async_stream_nolink`
- **Adapters**: Bridge between data structures and simulation logic
  - Single: One entity, direct return
  - Grid: Map positions, parallel processing, apply changes back
  - Gatekeeper: Lock/read/write pattern, parallel within locked set

**State Layer (Persistent)**
- **Gatekeeper**: Holds world grid, optional tick counter
- Survives Loop crashes
- All access through locking mechanism or direct functions

**Event Layer (Observability)**
- **Telemetry**: Metrics and performance monitoring (always available)
- **PubSub**: Domain events for UI updates (opt-in, configurable)

---

### 5. Read/Write Model with Change Struct

**Read (Tick N-1):**
- Original data passed as `Change.data`
- Immutable throughout stage execution
- Represents state from previous tick

**Write (Tick N):**
- Changes accumulate in `Change.changes`
- If step B depends on step A in same tick, reads from accumulated changes
- `Change.get/2` returns `origin + delta` for numbers, or change value for non-numbers

**Change Operations:**
```elixir
# Numeric (additive)
Change.change_by(change, :health, -10)     # Accumulate delta
Change.set(change, :health, 50)            # Set absolute (converts to delta)

# Non-numeric (replacement, last write wins)
Change.set(change, :status, :dead)

# Reading (sees accumulated changes)
Change.get(change, :health)  # origin + all deltas
Change.get(change, :status)  # latest value or origin

# Apply at end
Change.reduce(change)  # Returns updated data map
```

**Benefits:**
- Steps see consistent view (tick N-1)
- Steps can build on each other (read accumulated changes)
- Immutable simulation functions
- Adapter controls when to apply (via `reduce/1`)

---

### 6. Observability via Telemetry & PubSub

**Two complementary systems:**

#### Telemetry (Metrics & Performance)
**Use for**: Metrics, performance monitoring, system health, observability tools

**Events emitted:**
```elixir
# Queue level
[:ximula, :sim, :queue, :start]
[:ximula, :sim, :queue, :stop]

# Pipeline level
[:ximula, :sim, :pipeline, :start]
[:ximula, :sim, :pipeline, :stop]

# Stage level (all entities in stage)
[:ximula, :sim, :pipeline, :stage, :start]
[:ximula, :sim, :pipeline, :stage, :stop]
# measurements: %{duration: ..., ok: count, failed: count}

# Entity level (per entity in stage)
[:ximula, :sim, :pipeline, :stage, :entity, :start]
[:ximula, :sim, :pipeline, :stage, :entity, :stop]

# Step level (per step per entity)
[:ximula, :sim, :pipeline, :stage, :step, :start]
[:ximula, :sim, :pipeline, :stage, :step, :stop]
# metadata: %{change: ..., module: ..., function: ...}
```

**Integration**: LiveDashboard, StatsD, Prometheus, custom reporters

#### PubSub (Domain Events & Real-time Updates)
**Use for**: Real-time UI updates (LiveView), custom domain events, entity state changes

**Topic Structure:**
```
sim:pipeline:#{pipeline_name}
sim:pipeline:stage:#{stage_name}
sim:pipeline:stage:#{stage_name}:entity
sim:pipeline:stage:entity:step
```

**Notification Configuration:**

Pipeline level:
- `:none` - No notifications
- `:metric` - Telemetry only
- `:event` - PubSub only
- `:event_metric` - Both

Stage level:
- `%{all: :metric, entity: :none}` - Stage metrics, no entity events
- `%{all: :event, entity: {:metric, filter}}` - Stage events, filtered entity metrics

Step level:
- `{:metric, filter}` - Filtered telemetry (filter is required)
- `{:event, filter}` - Filtered PubSub events
- `{:event_metric, filter}` - Both, filtered

**Filter Functions:**
```elixir
# Filter by position
notify: {:metric, fn change -> Change.get(change, :position) == {0, 0} end}

# Filter by field state
notify: {:event, fn field -> field.urgent == true end}

# Always notify
notify: {:metric, fn _ -> true end}
```

**When to use which:**
- **Telemetry**: Always on, lightweight, for metrics and performance
- **PubSub**: Opt-in, heavier payloads, for domain events and UI updates
- **Both**: Critical events that need visibility and metrics

---

### 7. Parallelization Rules

**✅ Can parallelize:**
- Different entities in same stage (via TaskRunner)
- Different simulations on same entity (different stages)

**❌ Cannot parallelize:**
- Same entity within same stage (sequential steps)
- Stages within pipeline (sequential execution)

**TaskRunner Implementation:**
```elixir
# Uses Task.Supervisor.async_stream_nolink
TaskRunner.sim(
  entities,
  {module, func, args},
  supervisor,
  opts  # includes max_concurrency
)

# Returns: %{ok: [...], exit: [...]}
# Filters out :no_change results automatically
```

**Performance Optimization:**
- `max_concurrency` option limits parallel tasks
- `ordered: false` for better performance
- `zip_input_on_exit: true` to see which entity failed
- TaskRunner filters out `:no_change` results

---

### 8. Error Handling

**TaskRunner Level:**
```elixir
# Groups results by state
%{
  ok: [result1, result2, ...],     # Successful executions
  exit: [{entity, {reason, stacktrace}}, ...]  # Failed executions
}

# Pipeline.handle_sim_results checks:
# - If all failed → {:error, formatted_errors}
# - If any succeeded → {:ok, successful_results}
```

**Stage Level:**
```elixir
# Stage execution wraps adapter results
case adapter.run_stage(stage, result) do
  {:ok, result} -> continue with next stage
  {:error, reason} -> raise "sim failed with #{inspect(reason)}"
end
```

**Loop Level:**
```elixir
# Task failure monitoring
def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  log_error(ref, reason, state)  # Log which queue failed
  {:noreply, %{state | queues: reset_queue_task!(state.queues, ref)}}
end

# Queue too slow warning
def handle_telemetry(event, %{duration: duration}, %{interval: interval}, _) do
  if duration > interval * 1_000 do
    Logger.warning("queue took #{duration}μs, but interval is #{interval * 1_000}μs")
  end
end
```

**Best Practices:**
- Steps should handle errors internally (return change without raise)
- Use `on_error: :raise` (default) or implement custom error handling
- Monitor telemetry for performance issues
- Log queue failures for debugging

---

## Module Structure

```
Ximula.Sim/
├── Pipeline.ex                    # Pipeline builder & executor
│   ├── new_pipeline/1             # Create pipeline
│   ├── add_stage/2                # Add stage to pipeline
│   ├── add_step/4                 # Add step to current stage
│   ├── execute/2                  # Execute pipeline
│   ├── run_tasks/4                # Delegate to TaskRunner
│   ├── execute_steps/2            # Run steps on entity
│   └── execute_step/2             # Run single step
│
├── TaskRunner.ex                  # Parallel task execution
│   ├── sim/4                      # Execute entities in parallel
│   └── benchmark/1                # Performance timing
│
├── StageAdapter/                  # Data structure adapters
│   ├── Single.ex                  # Single entity: direct execution
│   ├── Grid.ex                    # Grid parallel: map positions
│   └── Gatekeeper.ex              # Locked entities: lock/read/write pattern
│
├── Loop.ex                        # Orchestration GenServer
│   ├── add_queue/2                # Add/replace queue
│   ├── start_sim/1                # Start all queues
│   ├── stop_sim/1                 # Stop all queues
│   ├── handle_info/2              # Timer ticks, task monitoring
│   └── handle_telemetry/4         # Performance monitoring
│
├── Queue.ex                       # Queue struct & execution
│   ├── %Queue{}                   # name, interval, func, timer, task
│   ├── add_pipeline/3             # Helper: wrap Pipeline.execute in func
│   └── execute/2                  # Run queue.func with optional args
│
├── Change.ex                      # Changeset utilities
│   ├── get/2                      # Read current value (origin + changes)
│   ├── change_by/3                # Accumulate numeric delta
│   ├── set/3                      # Set absolute value (converts to delta)
│   └── reduce/1                   # Apply all changes to origin
│
├── Notify.ex                      # Telemetry + PubSub
│   ├── build_*_notification/1     # Parse notify configs
│   ├── measure_*/2-3              # Wrap execution with events
│   └── broadcast/3                # Send PubSub events
│
└── Telemetry.ex                   # (If exists) Event definitions

External Dependencies:
├── Ximula.Gatekeeper.Agent        # State holder (wraps Agent)
├── Ximula.Grid                    # Grid data structure
├── Phoenix.PubSub                 # Event broadcasting
└── Task.Supervisor                # Parallel task execution
```

---

## Supervision Tree

```elixir
children = [
  # World data (persistent, locked access)
  # Two-part setup: Agent + Gatekeeper wrapper
  Ximula.Gatekeeper.Agent.agent_spec(MyWorld, data: nil, name: :world),
  {Ximula.Gatekeeper.Agent, name: :gatekeeper, agent: :world},
  
  # Event broadcasting
  {Phoenix.PubSub, name: :my_pub_sub},
  
  # Task execution (2 supervisors: loop tasks + sim tasks)
  {Task.Supervisor, name: :loop_task_supervisor},
  {Task.Supervisor, name: :task_runner_supervisor},
  
  # Orchestration (queues, timers)
  {Ximula.Sim.Loop,
    name: :my_sim_loop,
    supervisor: :loop_task_supervisor,
    sim_args: []  # Optional global args
  }
]

# Use :rest_for_one strategy
# If Gatekeeper crashes → everything restarts (data invalid)
# If Loop crashes → Gatekeeper survives (data persists)
Supervisor.start_link(children, strategy: :rest_for_one)

# Initialize world
Gatekeeper.direct_set(:gatekeeper, fn _ -> 
  Torus.create(100, 100, &initial_field/2)
end)

# Build pipeline (static definition)
pipeline = 
  Pipeline.new_pipeline(name: "world", notify: :metric, pubsub: :my_pub_sub)
  |> Pipeline.add_stage(
    adapter: StageAdapter.Gatekeeper,
    name: "vegetation",
    notify: %{all: :metric, entity: :none},
    gatekeeper: :gatekeeper,
    read_fun: &MySimulation.get_field/2,
    write_fun: &MySimulation.put_field/2
  )
  |> Pipeline.add_step(VegetationSim, :grow)

# Create queues with filters
urgent_queue = %Queue{
  name: :urgent,
  interval: 100,
  func: fn ->
    positions = Gatekeeper.get(:gatekeeper, fn grid ->
      Grid.positions(grid)
      |> Enum.filter(&Grid.get(grid, &1).urgent)
    end)
    Pipeline.execute(pipeline, %{
      data: positions,
      opts: [
        gatekeeper: :gatekeeper,
        supervisor: :task_runner_supervisor
      ]
    })
  end
}

normal_queue = %Queue{
  name: :normal,
  interval: 1_000
} |> Queue.add_pipeline(pipeline, %{
  data: MySimulation.positions(:gatekeeper),
  opts: [gatekeeper: :gatekeeper, supervisor: :task_runner_supervisor]
})

# Add queues and start
Loop.add_queue(:my_sim_loop, urgent_queue)
Loop.add_queue(:my_sim_loop, normal_queue)
Loop.start_sim(:my_sim_loop)
```

---

## Data Flow Example

**Tick N execution with dynamic filtering:**

1. **Tick Start (Queue Timer)**
   - Timer fires: `{:tick, queue}`
   - Loop receives message: `handle_info({:tick, queue}, state)`
   - Loop executes: `Queue.execute(queue, sim_args)`

2. **Queue Execution**
   - `queue.func()` runs (in supervised task)
   - Filters Gatekeeper: Gets urgent positions `[{3,5}, {15,20}]`
   - Calls: `Pipeline.execute(pipeline, %{data: positions, opts: [...]})`

3. **Pipeline Execution**
   - Telemetry: `[:ximula, :sim, :pipeline, :start]`
   - Loops through stages: `Enum.reduce(stages, result, &execute_stage/2)`

4. **Stage 1: Vegetation (Gatekeeper Adapter)**
   - Telemetry: `[:ximula, :sim, :pipeline, :stage, :start]`
   - `StageAdapter.Gatekeeper.run_stage(stage, %{data: positions, opts: opts})`
   - Calls: `Pipeline.run_tasks(positions, {Gatekeeper, :run_entity}, stage, opts)`
   - TaskRunner spawns 2 parallel tasks

5. **Entity Processing (Parallel)**
   - Task 1: Position {3,5}
     - `run_entity({3,5}, stage)` locks position
     - `read_fun.({3,5}, :gatekeeper)` → `%{vegetation: 100, urgent: true}`
     - `Pipeline.execute_steps(field, stage)` → `Enum.reduce(steps, %Change{data: field}, ...)`
     - Step: `VegetationSim.grow(change)` → `Change.change_by(change, :vegetation, 1)`
     - `Change.reduce()` → `%{vegetation: 101, urgent: true}`
     - `write_fun.(result, :gatekeeper)` → Writes back, returns position
   - Task 2: Position {15,20} (same process)
   - Both tasks complete, results collected

6. **Results & State Update**
   - TaskRunner returns: `%{ok: [{3,5}, {15,20}], exit: []}`
   - Telemetry: `[:ximula, :sim, :pipeline, :stage, :stop]` with counts
   - Pipeline continues to next stage (if any)
   - Pipeline completes
   - Telemetry: `[:ximula, :sim, :pipeline, :stop]`

7. **Task Completion**
   - Loop receives: `{task_ref, result}`
   - Clears task reference: `reset_queue_task!(queues, ref)`
   - Queue ready for next tick

8. **Next Tick (100ms later)**
   - Timer fires again
   - Filter runs fresh: Maybe different positions now urgent
   - Natural "migration" via state changes

---

## Configuration

**Application Level:**
```elixir
config :ximula,
  pubsub: MyApp.PubSub  # Default PubSub module
```

**Pipeline (Static Definition):**
```elixir
# As data structure
pipeline = %{
  stages: [...],
  name: "world",
  notify: :event_metric,
  pubsub: :my_pub_sub
}

# Or using builder
pipeline = 
  Pipeline.new_pipeline(name: "world", notify: :metric, pubsub: :my_pub_sub)
  |> Pipeline.add_stage(
    adapter: StageAdapter.Gatekeeper,
    name: "vegetation",
    notify: %{all: :metric, entity: {:event_metric, filter}},
    gatekeeper: :gatekeeper,
    read_fun: &Module.read/2,
    write_fun: &Module.write/2,
    pubsub: :my_pub_sub
  )
  |> Pipeline.add_step(
    Module, 
    :function,
    notify: {:metric, fn change -> Change.get(change, :position) == {0,0} end},
    pubsub: :my_pub_sub
  )
```

**Loop (Initial State):**
```elixir
{Loop, 
  name: :my_sim_loop,
  supervisor: :loop_task_supervisor,
  sim_args: []  # Optional global args
}

# Add queues dynamically (before starting)
Loop.add_queue(:my_sim_loop, queue1)
Loop.add_queue(:my_sim_loop, queue2)

# Cannot add queues while running
Loop.start_sim(:my_sim_loop)
```

**Queue (Two Patterns):**

Pattern 1: Custom func with filter logic
```elixir
%Queue{
  name: :urgent,
  interval: 100,
  func: fn ->
    # Custom filter + execute
    positions = filter_urgent_positions()
    Pipeline.execute(pipeline, %{data: positions, opts: [...]})
  end
}
```

Pattern 2: Using add_pipeline helper
```elixir
%Queue{name: :normal, interval: 1_000}
|> Queue.add_pipeline(pipeline, %{
  data: all_positions(),  # Can be static or dynamic
  opts: [gatekeeper: :gatekeeper, supervisor: :task_runner]
})
```

---

## Testing Patterns

**Pure Simulation Functions:**
```elixir
test "vegetation grows when water available" do
  change = %Change{
    data: %{vegetation: 100, water: 50},
    changes: %{}
  }
  
  result = VegetationSim.grow(change)
  
  assert Change.get(result, :vegetation) == 101
  assert Change.get(result, :water) == 49
end
```

**Pipeline Execution:**
```elixir
test "pipeline executes stages in order" do
  pipeline = 
    Pipeline.new_pipeline()
    |> Pipeline.add_stage(adapter: Single)
    |> Pipeline.add_step(Module, :step1)
    |> Pipeline.add_stage(adapter: Single)
    |> Pipeline.add_step(Module, :step2)
  
  {:ok, result} = Pipeline.execute(pipeline, %{
    data: initial_data,
    opts: []
  })
  
  assert result.stage1_completed == true
  assert result.stage2_completed == true
end
```

**Queue Filtering:**
```elixir
test "queue filters urgent positions" do
  # Setup Gatekeeper with test data
  Gatekeeper.direct_set(:gatekeeper, fn _ -> test_grid end)
  
  # Execute queue
  queue = create_urgent_queue()
  result = Queue.execute(queue, [])
  
  # Verify only urgent positions processed
  assert length(result) == 2  # Only 2 urgent fields
end
```

**Telemetry Events:**
```elixir
test "pipeline emits telemetry events" do
  :telemetry.attach("test", [:ximula, :sim, :pipeline, :stop], fn event, measurements, meta, _ ->
    send(self(), {:telemetry, event, measurements, meta})
  end, nil)
  
  Pipeline.execute(pipeline, state)
  
  assert_receive {:telemetry, [:ximula, :sim, :pipeline, :stop], %{duration: _}, %{name: "test"}}
end
```

---

## Performance Considerations

**Queue Filtering:**
- Filter runs fresh each tick (overhead depends on grid size)
- For large grids (10,000+ cells), consider:
  - Track urgent positions in separate structure
  - Use ETS index for fast lookups
  - Short-circuit if no matches expected
  - Cache filter results between ticks with invalidation

**TaskRunner Parallelism:**
- `max_concurrency` option limits parallel tasks
- Default: unlimited (uses all available cores)
- Balance: too low = underutilized, too high = context switching overhead
- Start with: `max_concurrency: System.schedulers_online() * 2`

**Change Struct:**
- Lightweight (just two maps)
- No deep copying (immutable references)
- Reduce called once per entity at end of stage

**Telemetry Overhead:**
- Minimal for `:metric` (just timing)
- Filter functions for steps reduce event count
- Use `:none` for high-frequency, non-critical steps

**PubSub Events:**
- Heavier than telemetry (serialization + broadcasting)
- Use filters to limit event volume
- Consider batching for high-frequency events

**Gatekeeper Locking:**
- Locks acquired per entity (fine-grained)
- No contention if entities don't overlap
- Grid adapter doesn't use locking (better for independent cells)

---

## Common Patterns

### Pattern 1: Multi-Queue Simulation

```elixir
# High-frequency queue for time-critical updates
urgent_queue = %Queue{
  name: :urgent,
  interval: 100,
  func: fn -> 
    filter_and_execute(&(&1.urgent), urgent_pipeline)
  end
}

# Normal frequency for regular updates
normal_queue = %Queue{
  name: :normal,
  interval: 1_000,
  func: fn ->
    filter_and_execute(&(!&1.urgent), normal_pipeline)
  end
}

# Low frequency for background tasks
maintenance_queue = %Queue{
  name: :maintenance,
  interval: 10_000,
  func: fn ->
    execute_maintenance_pipeline()
  end
}
```

### Pattern 2: Multi-Stage Pipeline

```elixir
pipeline = 
  Pipeline.new_pipeline(name: "world_sim")
  # Stage 1: Independent cell updates (Grid adapter)
  |> Pipeline.add_stage(adapter: Grid, name: "vegetation")
  |> Pipeline.add_step(Vegetation, :grow)
  |> Pipeline.add_step(Vegetation, :spread_seeds)
  
  # Stage 2: Population consumes resources (Gatekeeper for coordination)
  |> Pipeline.add_stage(
    adapter: Gatekeeper,
    name: "population",
    gatekeeper: :gatekeeper,
    read_fun: &read_settlement/2,
    write_fun: &write_settlement/2
  )
  |> Pipeline.add_step(Population, :consume_food)
  |> Pipeline.add_step(Population, :reproduce)
  
  # Stage 3: Movement (requires locking)
  |> Pipeline.add_stage(
    adapter: Gatekeeper,
    name: "movement",
    gatekeeper: :gatekeeper,
    read_fun: &read_entity/2,
    write_fun: &write_entity/2
  )
  |> Pipeline.add_step(Movement, :calculate_destination)
  |> Pipeline.add_step(Movement, :move)
```

### Pattern 3: Conditional Processing

```elixir
# Step returns :no_change when nothing to do
def grow_crops(%Change{} = change) do
  water = Change.get(change, :water)
  
  if water > 0 do
    change
    |> Change.change_by(:vegetation, calculate_growth(water))
    |> Change.change_by(:water, -1)
  else
    :no_change  # Filtered out by TaskRunner
  end
end
```

### Pattern 4: Step Dependency

```elixir
# Step B reads from Step A's changes in same tick
def consume_food(%Change{} = change) do
  # Reads accumulated changes from grow_crops
  current_food = Change.get(change, :food)  # Includes growth from same tick
  
  if current_food >= 10 do
    change
    |> Change.change_by(:food, -10)
    |> Change.change_by(:health, 5)
  else
    change
    |> Change.set(:health_status, :starving)
  end
end
```

---

## Open Questions & Future Considerations

### Implementation

1. **Queue Filter Optimization**: 
   - How to efficiently filter large grids? 
   - Should we add helper for tracking subsets (e.g., urgent positions)?
   - Consider ETS-based indexing for common filters?

2. **Filter Result Caching**: 
   - Cache filter results between ticks?
   - Invalidation strategy when field state changes?
   - Trade-off: memory vs CPU

3. **Error Recovery**:
   - Should stages have rollback capability?
   - How to handle partial success in stage?
   - Retry logic for transient failures?

### Features

4. **Persistence**: 
   - Should Gatekeeper support automatic persistence?
   - Snapshot strategy (every N ticks, on demand, periodic)?
   - Integration with external storage (ETS, Mnesia, DB)?

5. **History & Replay**:
   - Track history of ticks for debugging?
   - Replay mechanism for testing?
   - Time-travel debugging support?

6. **Dynamic Pipelines**:
   - Allow runtime pipeline modification?
   - Hot-reload simulation steps?
   - Or keep pipelines static for predictability?

### Advanced

7. **Step Metadata & Validation**:
   - Should steps declare `@reads` and `@writes` for validation?
   - Compile-time dependency checking?
   - Automatic change tracking?

8. **Multi-World Support**:
   - How to handle multiple independent simulations?
   - One Loop per world? Shared Loop with world routing?
   - Separate Gatekeepers per world?

9. **Distributed Simulation**:
   - Can simulation span multiple nodes?
   - Partition world across nodes?
   - Cross-node Gatekeeper coordination?

10. **Performance Monitoring**:
    - Built-in performance dashboard?
    - Automatic bottleneck detection?
    - Profiling integration?

---

## Quick Reference

### Core Types

```elixir
# Queue
%Queue{
  name: atom(),
  interval: integer(),  # milliseconds
  func: (() -> any()) | {module(), atom(), keyword()},
  timer: reference() | nil,
  task: Task.t() | nil
}

# Pipeline
%{
  stages: [stage()],
  name: String.t(),
  notify: :none | :metric | :event | :event_metric,
  pubsub: atom()
}

# Stage
%{
  adapter: module(),
  steps: [step()],
  notify: %{all: notify_type(), entity: notify_type() | {notify_type(), filter()}},
  name: String.t(),
  # Gatekeeper adapter specific:
  gatekeeper: atom(),
  read_fun: (key, gatekeeper -> entity),
  write_fun: (entity, gatekeeper -> key),
  pubsub: atom()
}

# Step
%{
  module: module(),
  function: atom(),
  notify: {:none | :metric | :event | :event_metric, filter() | nil},
  pubsub: atom()
}

# Change
%Change{
  data: map(),     # Immutable origin (tick N-1)
  changes: map()   # Accumulated changes (tick N)
}
```

### Key Functions

```elixir
# Loop
Loop.add_queue(loop, %Queue{})
Loop.start_sim(loop)
Loop.stop_sim(loop)

# Pipeline
Pipeline.new_pipeline(opts)
Pipeline.add_stage(pipeline, opts)
Pipeline.add_step(pipeline, module, function, opts)
Pipeline.execute(pipeline, %{data: ..., opts: [...]})

# Queue
Queue.add_pipeline(%Queue{}, pipeline, %{data: ..., opts: [...]})
Queue.execute(queue, global_args)

# Change
Change.get(change, key)
Change.change_by(change, key, delta)
Change.set(change, key, value)
Change.reduce(change)

# TaskRunner
TaskRunner.sim(entities, {module, func, args}, supervisor, opts)

# Gatekeeper
Gatekeeper.direct_set(gatekeeper, fn state -> new_state end)
Gatekeeper.get(gatekeeper, fn state -> result end)
Gatekeeper.lock(gatekeeper, key, fn state -> result end)
Gatekeeper.update(gatekeeper, key, value, fn state -> new_state end)
```

### Telemetry Events

```
[:ximula, :sim, :queue, :start | :stop]
[:ximula, :sim, :pipeline, :start | :stop]
[:ximula, :sim, :pipeline, :stage, :start | :stop]
[:ximula, :sim, :pipeline, :stage, :entity, :start | :stop]
[:ximula, :sim, :pipeline, :stage, :step, :start | :stop]
```

### PubSub Topics

```
sim:pipeline:#{pipeline_name}
sim:pipeline:stage:#{stage_name}
sim:pipeline:stage:#{stage_name}:entity
sim:pipeline:stage:entity:step
```