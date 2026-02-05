package crowd

import "core:math"
import "../recast"

Proximity_Grid :: struct {
	cell_size:     f32,
	inv_cell_size: f32,
	pool:          [dynamic]Grid_Item,
	pool_head:     int,
	buckets:       [dynamic]u16,
	bounds:        [4]i32,
}

Grid_Item :: struct {
	id:   u16,
	x:    i16,
	y:    i16,
	next: u16,
}

create_proximity_grid :: proc(pool_size: int, cell_size: f32, allocator := context.allocator) -> (grid: ^Proximity_Grid, ok: bool) {
	if pool_size <= 0 || cell_size <= 0 {
		return nil, false
	}
	context.allocator = allocator
	grid = new(Proximity_Grid)
	grid.cell_size = cell_size
	grid.inv_cell_size = 1.0 / cell_size
	grid.pool = make([dynamic]Grid_Item, 0, pool_size)
	grid.buckets = make([dynamic]u16, 0)
	grid.bounds = {0, 0, 0, 0}
	return grid, true
}

destroy_proximity_grid :: proc(grid: ^Proximity_Grid) {
	if grid == nil do return
	delete(grid.pool)
	delete(grid.buckets)
	free(grid)
}

proximity_grid_clear :: proc(grid: ^Proximity_Grid) {
	clear(&grid.pool)
	grid.pool_head = 0
	clear(&grid.buckets)
	grid.bounds = {0, 0, 0, 0}
}

proximity_grid_add_item :: proc(grid: ^Proximity_Grid, id: u16, minx: f32, miny: f32, maxx: f32, maxy: f32) {
	iminx := i32(math.floor(minx * grid.inv_cell_size))
	iminy := i32(math.floor(miny * grid.inv_cell_size))
	imaxx := i32(math.floor(maxx * grid.inv_cell_size))
	imaxy := i32(math.floor(maxy * grid.inv_cell_size))

	if len(grid.buckets) == 0 {
		grid.bounds[0] = iminx
		grid.bounds[1] = iminy
		grid.bounds[2] = imaxx
		grid.bounds[3] = imaxy
	} else {
		grid.bounds[0] = min(grid.bounds[0], iminx)
		grid.bounds[1] = min(grid.bounds[1], iminy)
		grid.bounds[2] = max(grid.bounds[2], imaxx)
		grid.bounds[3] = max(grid.bounds[3], imaxy)
	}

	w := grid.bounds[2] - grid.bounds[0] + 1
	h := grid.bounds[3] - grid.bounds[1] + 1

	if w * h > i32(len(grid.buckets)) {
		new_size := w * h
		resize(&grid.buckets, int(new_size))
		for i in 0..<new_size {
			grid.buckets[i] = 0xffff
		}
	}

	for y in iminy..=imaxy {
		for x in iminx..=imaxx {
			if len(grid.pool) >= cap(grid.pool) do continue

			item := Grid_Item{
				id = id,
				x = i16(x),
				y = i16(y),
				next = 0xffff,
			}

			bucket_idx := (y - grid.bounds[1]) * w + (x - grid.bounds[0])
			item.next = grid.buckets[bucket_idx]
			grid.buckets[bucket_idx] = u16(len(grid.pool))
			append(&grid.pool, item)
		}
	}
}

proximity_grid_query_items :: proc(grid: ^Proximity_Grid, minx: f32, miny: f32, maxx: f32, maxy: f32,
                                   ids: []u16, max_ids: int) -> int {
	iminx := i32(math.floor(minx * grid.inv_cell_size))
	iminy := i32(math.floor(miny * grid.inv_cell_size))
	imaxx := i32(math.floor(maxx * grid.inv_cell_size))
	imaxy := i32(math.floor(maxy * grid.inv_cell_size))

	n := 0
	w := grid.bounds[2] - grid.bounds[0] + 1

	for y in iminy..=imaxy {
		for x in iminx..=imaxx {
			if x < grid.bounds[0] || x > grid.bounds[2] do continue
			if y < grid.bounds[1] || y > grid.bounds[3] do continue

			bucket_idx := (y - grid.bounds[1]) * w + (x - grid.bounds[0])
			idx := grid.buckets[bucket_idx]
			for idx != 0xffff {
				item := &grid.pool[idx]

				already_added := false
				for i in 0..<n {
					if ids[i] == item.id {
						already_added = true
						break
					}
				}

				if !already_added && n < max_ids {
					ids[n] = item.id
					n += 1
				}

				idx = item.next
			}
		}
	}

	return n
}

proximity_grid_get_item_count_at :: proc(grid: ^Proximity_Grid, x: i32, y: i32) -> int {
	if x < grid.bounds[0] || x > grid.bounds[2] do return 0
	if y < grid.bounds[1] || y > grid.bounds[3] do return 0

	w := grid.bounds[2] - grid.bounds[0] + 1
	bucket_idx := (y - grid.bounds[1]) * w + (x - grid.bounds[0])

	n := 0
	idx := grid.buckets[bucket_idx]
	for idx != 0xffff {
		n += 1
		idx = grid.pool[idx].next
	}
	return n
}
