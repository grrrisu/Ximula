# Changelog

## dev

Grid:
- changed behaviour of `Grid.map`, after applying the function it doesn't order or change the list anymore
- besides the functiion `Grid.values` there's `Grid.now postitions_and_values` as well.
- sorted_list asc(cending) `Grid.sorted_list(grid, :asc)` and cartesian `Grid.sorted_list(grid, :cartesian)`

AccessProxy:
- `AccessProxy.release` the lock and allow the next to continue

## 0.1.0

- Extracted Grid and Torus from Thundermoon
- Extracted AccessProxy from Livebook
