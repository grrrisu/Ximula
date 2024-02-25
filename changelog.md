# Changelog

## dev

Sim.Loop:

- remove `set_queue`, `add_queue` now replaces queues with the same name

Grid:

- allow accessing a grid with a tuple of coordination values `Grid.get(grid, {x, y})`


## 0.2.0

Grid:

- changed behaviour of `Grid.map`, after applying the function it doesn't order or change the list anymore
- besides the functiion `Grid.values` there's now `Grid.postitions_and_values` as well.
- sorted_list asc(cending) `Grid.sorted_list(grid, :asc)` and cartesian `Grid.sorted_list(grid, :cartesian)`

AccessProxy:

- `AccessProxy.release` the lock and allow the next to continue
- `AccessData` Agent-like module that uses keys to lock part of its data

Sim:

- extracted Sim modules Simulator, Loop and Queue
- handle timeouts in Sim.Loop

## 0.1.0

- Extracted Grid and Torus from Thundermoon
- Extracted AccessProxy from Livebook
