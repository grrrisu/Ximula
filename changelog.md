# Changelog

## 0.3.0

Sim:

- Loop: remove `set_queue`, `add_queue` now replaces queues with the same name. But can not be addes while the loop is running.
- Simulator: allow to set max_concurrency
- Simulator: remove id_func, in case of exit the function now returns the entire entity

Grid:

- allow accessing a grid with a tuple of coordination values `Grid.get(grid, {x, y})`

AccessData:

- rename `get_by` to `get`
- function to `set` all data at once
- rename lock and update functions:
  
```elixir
data = AccessData.lock({1,2}, pid, &Grid.get(&1, {1,2}) end)
data = AccessData.lock([{1,1}, {1,2}], pid, &[Grid.get(&1, {1,1}), Grid.get(&1, {1,2})])
:ok = AccessData.lock({1,2}, pid)

data = AccessData.lock_key({1,2}, pid, &Grid.get(&1, &2) end)
:ok = AccessData.lock_key({1,2}, pid)

[data, data] = AccessData.lock_list([{0, 2}, {1,2}], pid, &Grid.get(&1, &2))
[:ok, :ok] = AccessData.lock_list([{0, 2}, {1,2}], pid)

:ok = AccessData.lock_list([{0,2}, {1,2}], pid)
AccessData.update({0,2}, pid, &Grid.apply_changes(&1, [{{0,2}, new_data}]))
AccessData.update([{0,2}, {1,2}], pid, &Grid.apply_changes(&1, [{{0,2}, new_data}, {{1,2}, new_data}]))

:ok = AccessData.lock({0,2}, grid)
AccessData.update_key({{1,2}, new_data}, pid, &Grid.put(&1, &2, &3))

:ok = AccessData.lock_list([{0,2}, {1,2}], grid)
AccessData.update_list([{{0,2}, new_data}, {{1,2}, new_data}], &Grid.put(&1, &2, &3))
```


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
