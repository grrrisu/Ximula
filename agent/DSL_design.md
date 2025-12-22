# Ximula DSL - Design Concepts

## Goal
Create an expressive, declarative DSL for defining simulations that:
- Is readable by non-Elixir experts
- Reduces boilerplate
- Makes simulation structure clear at a glance
- Supports compile-time validation
- Enables composition and reusability

---

## Design Philosophy

### Current Pain Points
```elixir
# Too much ceremony
pipeline = 
  Pipeline.new_pipeline(name: "world", notify: :metric, pubsub: :my_pub_sub)
  |> Pipeline.add_stage(
    adapter: StageAdapter.Gatekeeper,
    name: "vegetation",
    notify: %{all: :metric, entity: {:event_metric, filter}},
    gatekeeper: :gatekeeper,
    read_fun: &Module.read/2,
    write_fun: &Module.write/2
  )
  |> Pipeline.add_step(Module, :function, notify: {:metric, filter})

# Queue creation is verbose
%Queue{name: :urgent, interval: 100}
|> Queue.add_pipeline(pipeline, %{
  data: positions(:gatekeeper),
  opts: [gatekeeper: :gatekeeper, supervisor: :task_runner]
})
```

### Desired Feel
```elixir
# Declarative, less ceremony
defmodule MySimulation do
  use Ximula.Sim.DSL
  
  simulation :world do
    gatekeeper :gatekeeper
    pubsub :my_pub_sub
    
    queue :urgent, interval: 100 do
      filter fn grid -> 
        Grid.positions(grid) |> Enum.filter(&Grid.get(grid, &1).urgent)
      end
      
      stage :vegetation, adapter: :gatekeeper do
        read &get_field/2
        write &put_field/2
        
        step VegetationSim, :grow
        step VegetationSim, :spread, notify: :metric
      end
    end
    
    queue :normal, interval: 1_000 do
      filter &all_positions/1
      
      stage :population, adapter: :gatekeeper do
        read &get_settlement/2
        write &put_settlement/2
        
        step Population, :consume
        step Population, :reproduce
      end
    end
  end
end

# Usage
MySimulation.start_link()
MySimulation.get_pipeline(:urgent)
MySimulation.get_queue(:normal)
```

---

## DSL Layers

### Layer 1: Simulation (Top Level)
**Purpose**: Define entire simulation with all queues and shared config

**What it provides:**
- Namespace for simulation
- Shared configuration (gatekeeper, pubsub, supervisors)
- Generated functions to access pipelines/queues
- Automatic supervision tree setup

**Conceptual API:**
```elixir
defmodule MyWorld do
  use Ximula.Sim.DSL
  
  simulation :world_sim do
    # Shared config
    gatekeeper :my_gatekeeper
    pubsub :my_pubsub
    supervisor :task_runner, :my_task_supervisor
    supervisor :loop, :my_loop_supervisor
    
    # Multiple queues
    queue :urgent, interval: 100 do ... end
    queue :normal, interval: 1_000 do ... end
    queue :maintenance, interval: 10_000 do ... end
  end
end

# Generated:
# MyWorld.child_spec/1 - for supervision tree
# MyWorld.get_queue(:urgent) - returns %Queue{}
# MyWorld.get_pipeline(:urgent) - returns pipeline map
# MyWorld.queues() - returns all queues
```

---

### Layer 2: Queue DSL
**Purpose**: Define when and what to process

**What it captures:**
- Timing (interval)
- Filtering logic (which entities)
- Pipeline to execute
- Queue-specific overrides

**Design decisions:**

1. **Filter as first-class concept**
```elixir
queue :urgent, interval: 100 do
  # Option 1: Inline function
  filter fn grid -> 
    Grid.positions(grid) |> Enum.filter(&urgent?/1)
  end
  
  # Option 2: Named function
  filter &urgent_positions/1
  
  # Option 3: DSL shorthand
  filter where: :urgent, equals: true
  
  stage ... do ... end
end
```

2. **Multiple pipelines per queue?**
```elixir
# Should we support this?
queue :complex, interval: 100 do
  filter &urgent_positions/1
  
  pipeline :phase1 do
    stage :vegetation do ... end
  end
  
  pipeline :phase2, if: :winter do
    stage :freeze do ... end
  end
end

# Or keep it simple: one pipeline per queue
queue :urgent, interval: 100 do
  filter &urgent_positions/1
  stage :vegetation do ... end
  stage :population do ... end
end
```

**Recommendation**: Start simple (one implicit pipeline per queue), add named pipelines later if needed

---

### Layer 3: Stage DSL
**Purpose**: Define execution strategy and steps

**What it captures:**
- Adapter type
- Read/write functions (for Gatekeeper)
- Steps sequence
- Notification config

**Design decisions:**

1. **Adapter selection**
```elixir
# Option 1: Explicit keyword
stage :vegetation, adapter: :gatekeeper do ... end
stage :weather, adapter: :grid do ... end
stage :world_stats, adapter: :single do ... end

# Option 2: Infer from context
stage :vegetation do
  # Has read/write → must be Gatekeeper
  read &get_field/2
  write &put_field/2
  step ...
end

stage :weather do
  # No read/write, has grid data → Grid adapter
  step ...
end

# Option 3: Named adapter functions
stage :vegetation, gatekeeper: :my_gatekeeper do
  read &get_field/2
  write &put_field/2
end

stage :weather, grid: true do
  step ...
end
```

**Recommendation**: Option 3 (named adapters) - most explicit and readable

2. **Notification config**
```elixir
stage :vegetation, gatekeeper: :my_gatekeeper do
  # Stage-level notification
  notify :metric  # or :event, :event_metric, :none
  notify entity: {:metric, &filter/1}  # For entity-level
  
  # Step-level notification
  step VegetationSim, :grow, notify: {:metric, &at_origin?/1}
  step VegetationSim, :spread
end
```

3. **Read/Write pattern**
```elixir
# Should these be required or optional?
stage :vegetation, gatekeeper: :gatekeeper do
  # Option 1: Always required for gatekeeper
  read &get_field/2
  write &put_field/2
  
  # Option 2: Default to Grid.get/Grid.put if omitted
  # (assumes data is Grid)
  
  # Option 3: Named patterns
  read :field  # Uses predefined MySimulation.read_field/2
  write :field
end
```

**Recommendation**: Start with required read/write, add convenience defaults later

---

### Layer 4: Step DSL
**Purpose**: Define simulation logic sequence

**What it captures:**
- Module and function reference
- Notification configuration
- Step metadata (optional)

**Design decisions:**

1. **Step definition**
```elixir
# Option 1: Simple (current)
step VegetationSim, :grow
step VegetationSim, :spread, notify: {:metric, filter}

# Option 2: With guards/conditions
step VegetationSim, :grow, if: &has_water?/1
step VegetationSim, :spread, unless: &is_winter?/1

# Option 3: With metadata
step VegetationSim, :grow, reads: [:water, :soil], writes: [:vegetation]
step VegetationSim, :spread, reads: [:vegetation], writes: [:seeds]
```

**Recommendation**: Start with Option 1, add conditions later if needed

2. **Step grouping**
```elixir
# Should we support step groups/transactions?
stage :complex do
  group :growth do
    step Module, :check_soil
    step Module, :grow_crops
  end
  
  group :harvest, if: &is_autumn?/1 do
    step Module, :calculate_yield
    step Module, :harvest
  end
end
```

---

## Macro Implementation Hints

### 1. Use `__using__` to inject DSL
```elixir
defmodule Ximula.Sim.DSL do
  defmacro __using__(_opts) do
    quote do
      import Ximula.Sim.DSL
      Module.register_attribute(__MODULE__, :queues, accumulate: true)
      Module.register_attribute(__MODULE__, :simulation_config, accumulate: false)
      @before_compile Ximula.Sim.DSL
    end
  end
  
  defmacro __before_compile__(env) do
    # Generate child_spec, get_queue, get_pipeline functions
  end
end
```

### 2. Accumulate state during compilation
```elixir
defmacro simulation(name, do: block) do
  quote do
    @simulation_name unquote(name)
    unquote(block)
  end
end

defmacro queue(name, opts, do: block) do
  quote do
    # Push to @queues attribute
    @queues {unquote(name), unquote(opts), unquote(Macro.escape(block))}
    # Set context for nested macros
    var!(current_queue) = unquote(name)
    unquote(block)
  end
end
```

### 3. Build data structures at compile time
```elixir
defmacro __before_compile__(_env) do
  queues = Module.get_attribute(__MODULE__, :queues)
  
  # Generate functions
  quote do
    def queues(), do: unquote(Macro.escape(build_queues(queues)))
    
    def get_queue(name) do
      # ... lookup logic
    end
  end
end
```

### 4. Support nested context
```elixir
# Use variable injection for context
defmacro stage(name, opts, do: block) do
  quote do
    # Access parent context
    queue_name = var!(current_queue)
    
    # Set stage context
    var!(current_stage) = unquote(name)
    var!(stage_opts) = unquote(opts)
    
    unquote(block)
    
    # Accumulate stage into queue
    # ...
  end
end
```

---

## Validation & Error Messages

### Compile-time Validation
```elixir
# Check for required fields
defmacro stage(name, opts, do: block) do
  adapter = Keyword.get(opts, :adapter)
  
  unless adapter in [:single, :grid, :gatekeeper] do
    raise CompileError, 
      description: "stage requires :adapter option (:single, :grid, or :gatekeeper)"
  end
  
  # Continue with macro
end
```

### Helpful Error Messages
```elixir
# Instead of:
# ** (KeyError) key :gatekeeper not found

# Provide:
# ** (Ximula.Sim.ConfigError) Stage 'vegetation' with :gatekeeper adapter 
#    requires 'read' and 'write' functions to be defined.
#    
#    Add them inside the stage block:
#    
#      stage :vegetation, adapter: :gatekeeper do
#        read &MyModule.read_field/2
#        write &MyModule.write_field/2
#      end
```

---

## Progressive Enhancement

### Phase 1: Basic DSL
- `simulation` macro
- `queue` with interval
- `stage` with adapter
- `step` with module/function
- Generate Queue and Pipeline structs

### Phase 2: Filters & Notifications
- `filter` macro for queue filtering
- `notify` for stage/step notifications
- Filter function helpers

### Phase 3: Convenience Features
- Named read/write patterns
- Adapter inference
- Default configurations
- Helper macros (e.g., `where:` clause)

### Phase 4: Advanced Features
- Conditional steps (`if:`, `unless:`)
- Step grouping
- Multiple pipelines per queue
- Step metadata and validation
- Hot-reload support

---

## Alternative Approaches

### Approach A: Configuration-based DSL
**Like Ecto schemas - pure data, functions interpret**

```elixir
defmodule MySimulation do
  use Ximula.Sim.Config
  
  @simulation %{
    name: :world,
    gatekeeper: :gatekeeper,
    queues: [
      %{
        name: :urgent,
        interval: 100,
        filter: &urgent_positions/1,
        stages: [
          %{
            name: :vegetation,
            adapter: :gatekeeper,
            read: &get_field/2,
            write: &put_field/2,
            steps: [
              {VegetationSim, :grow},
              {VegetationSim, :spread}
            ]
          }
        ]
      }
    ]
  }
end
```

**Pros**: Simple, introspectable, easily serializable
**Cons**: More verbose, less IDE support, no compile-time validation

---

### Approach B: Builder pattern DSL
**Like Plug.Builder - explicit chaining**

```elixir
defmodule MySimulation do
  use Ximula.Sim.Builder
  
  simulation :world
  
  config :gatekeeper, :my_gatekeeper
  config :pubsub, :my_pubsub
  
  queue :urgent, interval: 100 do
    filter &urgent_positions/1
    
    stage :vegetation do
      adapter :gatekeeper
      read &get_field/2
      write &put_field/2
      
      step VegetationSim, :grow
      step VegetationSim, :spread
    end
  end
end
```

**Pros**: Familiar to Elixir developers, flexible
**Cons**: Less declarative, requires careful state management

---

### Approach C: Nested block DSL (Recommended)
**Like ExUnit describe/test - clear hierarchy**

```elixir
defmodule MySimulation do
  use Ximula.Sim.DSL
  
  simulation :world do
    gatekeeper :my_gatekeeper
    pubsub :my_pubsub
    
    queue :urgent, interval: 100 do
      filter &urgent_positions/1
      
      stage :vegetation, adapter: :gatekeeper do
        read &get_field/2
        write &put_field/2
        
        step VegetationSim, :grow
        step VegetationSim, :spread
      end
    end
  end
end
```

**Pros**: Most readable, clear hierarchy, familiar pattern
**Cons**: Macro complexity, nested context management

---

## Testing the DSL

### Unit Test Structure
```elixir
defmodule Ximula.Sim.DSLTest do
  use ExUnit.Case
  
  defmodule TestSimulation do
    use Ximula.Sim.DSL
    
    simulation :test do
      gatekeeper :test_gatekeeper
      
      queue :test_queue, interval: 100 do
        filter fn _ -> [{0, 0}] end
        
        stage :test_stage, adapter: :single do
          step TestModule, :test_step
        end
      end
    end
  end
  
  test "generates queue struct" do
    queue = TestSimulation.get_queue(:test_queue)
    assert queue.name == :test_queue
    assert queue.interval == 100
    assert is_function(queue.func)
  end
  
  test "generates pipeline struct" do
    pipeline = TestSimulation.get_pipeline(:test_queue)
    assert length(pipeline.stages) == 1
  end
end
```

---

## Documentation Strategy

### 1. Guide: "Getting Started with DSL"
Show complete example with explanations

### 2. Reference: "DSL Macros"
Document each macro with options and examples

### 3. Cookbook: "Common Patterns"
- Multiple queues
- Conditional stages
- Shared pipelines
- Testing strategies

### 4. Migration Guide
Show how to convert manual construction to DSL

---

## Key Design Questions to Decide

1. **One pipeline per queue, or multiple?**
   - Recommendation: Start with one, add named pipelines if needed

2. **Adapter inference or explicit?**
   - Recommendation: Explicit (clearer, less magic)

3. **Required vs optional read/write?**
   - Recommendation: Required for gatekeeper, add shortcuts later

4. **Filter DSL - function or mini-language?**
   - Recommendation: Function first, add `where:` shortcuts later

5. **Notification config - stage-level or step-level?**
   - Recommendation: Both (stage default, step override)

6. **Generate supervision tree or require manual setup?**
   - Recommendation: Generate child_spec, user adds to supervisor

7. **Support module attributes for config?**
   ```elixir
   @gatekeeper :my_gatekeeper
   
   simulation :world do
     gatekeeper @gatekeeper
   end
   ```
   - Recommendation: Yes, standard Elixir pattern

---

## Implementation Roadmap

### Milestone 1: Proof of Concept
- [ ] Basic `simulation` macro
- [ ] Basic `queue` macro with interval
- [ ] Generate simple Queue struct
- [ ] Test with one queue

### Milestone 2: Pipeline Generation
- [ ] `stage` macro
- [ ] `step` macro
- [ ] Generate Pipeline struct
- [ ] Test queue.func executes pipeline

### Milestone 3: Adapters
- [ ] `adapter` option handling
- [ ] `read`/`write` for Gatekeeper
- [ ] Validate adapter requirements
- [ ] Test all three adapters

### Milestone 4: Filters & Notifications
- [ ] `filter` macro
- [ ] `notify` configuration
- [ ] Test filtering logic
- [ ] Test notification events

### Milestone 5: Polish
- [ ] Better error messages
- [ ] Documentation
- [ ] Examples
- [ ] Migration guide

---

## Naming Considerations

**Module name options:**
- `Ximula.Sim.DSL` (clear purpose)
- `Ximula.Sim.Definition` (more formal)
- `Ximula.Sim.Schema` (like Ecto)
- `Ximula.Sim` (if DSL becomes primary interface)

**Macro name options:**
- `simulation` vs `defsimulation`
- `queue` vs `defqueue`
- `stage` vs `defstage`

**Recommendation**: Start with noun forms (`simulation`, `queue`, `stage`) - more declarative feel

---

## Success Criteria

The DSL is successful if:

1. **Readability**: Non-Elixir experts can understand simulation structure
2. **Conciseness**: 50% less boilerplate than manual construction
3. **Safety**: Compile-time validation catches configuration errors
4. **Flexibility**: Doesn't lock users into DSL (can still use manual construction)
5. **Documentation**: Clear examples and migration path
6. **Performance**: No runtime overhead vs manual construction

---

## Next Steps

1. **Prototype `simulation` macro** - Get basic structure working
2. **Test macro expansion** - Use `Macro.expand` to verify generated code
3. **Iterate on syntax** - Find the most readable form
4. **Add validation** - Helpful compile-time errors
5. **Document patterns** - Show common use cases
6. **Get feedback** - Test with real simulations