Ximula.Sim - Design Summary
Core Concept
A composable, pipeline-based simulation library for Elixir that separates simulation logic (pure functions) from execution strategy (parallel/sequential) and output handling (reduction/observation).

Key Design Decisions
1. Two-Level Pipeline Architecture
Tick Pipeline (Orchestration Level)

Defines sequence of stages that run in order
Each stage is a complete execute → simulate → reduce cycle
Ensures dependencies between stages (e.g., grow crops before feeding population)

Simulation Pipeline (Logic Level)

Defines steps within a simulation
Pure functions with pattern matching
Steps run sequentially within a stage, but entities can be processed in parallel

2. Separation of Concerns
Simulation Layer (Pure)

No processes, no side effects
Pattern-matched functions: def step(original_data, accumulated_changes, opts)
Returns: %{changes: %{key: value}}
Can optionally return cross-entity operations for Gatekeeper coordination

Execution Layer (Stateful)

Handles Tasks, GenServers, orchestration
Manages parallelism across entities
Integrates with Gatekeeper for cross-entity writes
Different executors for different strategies (Grid, Single)

Reduction Layer

Aggregates changes after simulation completes
Custom aggregators (sum, merge, chart data, etc.)
Runs at end of stage (not per-step, to avoid overhead)

3. Read/Write Model
Read (Tick N-1):

All processes read immutable state from previous tick
Safe for parallel reads
Passed as original_data parameter

Write (Tick N):

Changes accumulate in changeset structure
Passed as accumulated_changes parameter
If step B depends on step A in same tick, reads from accumulated_changes
Changes held until end of pipeline, then applied atomically

Cross-Entity Writes:

Use Gatekeeper for coordination
Simulation declares locks_needed and cross_entity_fn
Execution layer handles locking/unlocking

4. Observability via PubSub
Decoupled Event System:

Phoenix.PubSub for broadcasting events
Simulations don't know who's listening
Subscribers can join/leave at runtime

Topic Structure:
sim:#{sim_name}:#{scope}:#{identifier}

Examples:
- sim:world:tick:42
- sim:world:stage:grow_crops
- sim:world:step:grow_plants
- sim:world:entity:field:10:5
- sim:world:entity:field:*
Event Types:

:tick_start, :tick_complete
:stage_start, :stage_complete
:step_complete
Custom events from sim functions (for significant changes)

Selective Broadcasting:

Sim functions decide when to broadcast (e.g., only significant changes)
Prevents flooding with 50,000+ events per tick
Subscribers filter by topic granularity

5. Parallelization Rules
✅ Can parallelize:

Same simulation across different entities (grow crops on all fields)
Different simulations on same entity (crops + population on field A)

❌ Cannot parallelize:

Same simulation on same entity twice (never two crop growth tasks on field A)

Sequential when needed:

Stages with dependencies run in order
Within each stage, entities processed in parallel
Within each entity, steps run sequentially

6. Configuration
Global (Application Level):
elixirconfig :ximula_sim,
  pubsub: MyApp.PubSub,
  simulation_name: :world,
  broadcast_events: [:tick_start, :tick_complete, :stage_complete, :step_complete]
```

**Per Tick Pipeline:**
- Stage definitions
- Executor selection
- Simulation module
- Reducer selection

**Per Simulation:**
- Step functions
- Pattern matching for polymorphic behavior

---

## Architecture & Data Flow
```
┌─────────────────────────────────────────────────────────────┐
│                     TICK PIPELINE                            │
│  Defines: stage sequence, executor, simulation, reducer     │
│  Config: PubSub topics, broadcast settings                  │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ For each stage:
                         │
        ┌────────────────▼────────────────┐
        │      EXECUTION LAYER             │
        │  - GridExecutor / SingleExecutor │
        │  - Task.async_stream             │
        │  - Gatekeeper coordination       │
        │  - Broadcasts: stage_start       │
        └────────────────┬────────────────┘
                         │
                         │ For each entity (parallel):
                         │
        ┌────────────────▼────────────────┐
        │     SIMULATION LAYER             │
        │  Pipeline: step → step → step    │
        │  Pure functions:                 │
        │    (data, changes, opts)         │
        │      -> %{changes: ...}          │
        │  - Broadcasts: step_complete     │
        │  - Broadcasts: custom events     │
        └────────────────┬────────────────┘
                         │
                         │ Returns: list of changes per entity
                         │
        ┌────────────────▼────────────────┐
        │      REDUCTION LAYER             │
        │  - Aggregate changes             │
        │  - Output adapters               │
        │  - Broadcasts: stage_complete    │
        └────────────────┬────────────────┘
                         │
                         │ Apply changes → new state
                         │
                         ▼
                    Next Stage
                         │
                         ▼
                  Tick Complete
                         
                         
┌─────────────────────────────────────────────────────────────┐
│                  OBSERVERS (Decoupled)                       │
│  Subscribe to PubSub topics:                                │
│  - LiveView: "sim:world:entity:field:10:5"                  │
│  - LiveBook: "sim:world:stage:grow_crops"                   │
│  - Metrics: "sim:world:tick:*"                              │
│  - EventStore: "sim:world:*"                                │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Flow Example

**Tick N execution:**

1. **Tick Start**
   - Read immutable state from tick N-1
   - Broadcast `:tick_start` event

2. **Stage 1: grow_crops**
   - Broadcast `:stage_start`
   - GridExecutor spawns tasks for all fields (parallel)
   - Each field runs CropSimulation pipeline:
     - `check_soil(data, %{}, opts)` → `%{changes: %{soil: -1}}`
     - `apply_water(data, %{soil: -1}, opts)` → `%{changes: %{water: +10}}`
     - `grow_plants(data, %{soil: -1, water: +10}, opts)` → `%{changes: %{growth: +5}}`
     - Broadcast `:step_complete` for each step
   - Collect all changes: `[{field_a, changes_a}, {field_b, changes_b}, ...]`
   - SumAggregator reduces changes
   - Broadcast `:stage_complete`
   - Apply changes to state

3. **Stage 2: grow_population**
   - Now has updated food available from Stage 1
   - GridExecutor spawns tasks (parallel)
   - PopulationSimulation pipeline runs
   - Aggregate and apply changes

4. **Stage 3: population_movement**
   - Requires cross-entity coordination
   - GridExecutor collects all `locks_needed`
   - Uses Gatekeeper to lock affected entities
   - Runs `cross_entity_fn` for migrations
   - Gatekeeper.update_multi to apply changes
   - Release locks

5. **Tick Complete**
   - Final state for tick N committed
   - Broadcast `:tick_complete`
   - Becomes immutable read state for tick N+1

---

## Module Structure
```
Ximula.Sim/
├── Pipeline.ex                    # tick_pipeline macro & coordination
├── Simulation.ex                  # simulation pipeline macro & helpers
│
├── Executor/
│   ├── Behaviour.ex              # Executor behaviour definition
│   ├── Grid.ex                   # Parallel execution across entities
│   └── Single.ex                 # Single entity execution
│
├── Reducer/
│   ├── Behaviour.ex              # Reducer behaviour definition
│   ├── Sum.ex                    # Sum aggregator
│   ├── Merge.ex                  # Merge aggregator
│   └── Chart.ex                  # Chart data formatter
│
├── PubSub.ex                      # PubSub helpers & topic builders
├── Gatekeeper.ex                  # Integration with Ximula.Gatekeeper
├── TickServer.ex                  # GenServer for tick coordination
└── Changes.ex                     # Changeset utilities

Key Requirements
Functional Requirements

Support hierarchical simulations (world → region → field)
Allow parallel execution of independent entities
Ensure sequential execution of dependent stages
Handle cross-entity operations with locking
Provide observability without coupling
Support multiple output targets (LiveView, LiveBook, charts, logs)

Technical Requirements

Pure simulation functions (no side effects)
Immutable data throughout
Changes tracked separately from original data
Integration with Ximula.Gatekeeper for coordination
Phoenix.PubSub for event broadcasting
Configurable at application and pipeline levels

Performance Considerations

Minimize event broadcasting (selective, not every change)
Reduce once per stage (not per step)
Support parallel task execution
Efficient change aggregation

Developer Experience

Clear separation of concerns
Macro-based DSL for pipeline definition
Pattern matching for simulation logic
Flexible subscription model for observation
Easy to test (pure functions)
Easy to debug (granular events)


Open Questions for Implementation

Step metadata: Should steps declare @effects and @reads for validation?
Error handling: How to handle simulation step failures? Retry? Rollback?
Validation: Should changes be validatable (like Ecto changesets)?
History: Should the library track history of ticks for replay?
Dynamic pipelines: Any need for runtime pipeline modification?
WiederholenClaude kann Fehler machen. Bitte überprüfen Sie die Antworten.
