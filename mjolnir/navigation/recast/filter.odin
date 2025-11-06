package navigation_recast

import "../../geometry"
import "core:math/linalg"
import "core:slice"

// Maximum heightfield height constant
MAX_HEIGHTFIELD_HEIGHT :: 0xffff

// Get connection from compact span in given direction
get_con :: proc "contextless" (span: ^Compact_Span, dir: int) -> int {
  shift := u32(dir * 6)
  return int((span.con >> shift) & 0x3f)
}

// Set connection for compact span in given direction
set_con :: proc "contextless" (span: ^Compact_Span, dir: int, i: int) {
  shift := u32(dir * 6)
  span.con = (span.con & (~(0x3f << shift))) | (u32(i) << shift)
}

// Filter low hanging walkable obstacles
// Remove walkable spans that are below obstacles where the agent could walk over
filter_low_hanging_walkable_obstacles :: proc(
  walkable_climb: int,
  heightfield: ^Heightfield,
) {
  x_size := heightfield.width
  z_size := heightfield.height
  // Process each column
  for z in 0 ..< z_size {
    for x in 0 ..< x_size {
      previous_span: ^Span = nil
      previous_was_walkable := false
      previous_area_id: u8 = RC_NULL_AREA
      // For each span in the column
      for span := heightfield.spans[x + z * x_size];
          span != nil;
          span = span.next {
        walkable := span.area != RC_NULL_AREA
        // If current span is not walkable, but there is walkable span just below it
        // and the height difference is small enough for the agent to climb over,
        // mark the current span as walkable too
        if !walkable && previous_was_walkable && previous_span != nil {
          // Check if agent can climb from top of previous span to top of current span
          climb_height := int(span.smax) - int(previous_span.smax)
          if climb_height <= walkable_climb {
            span.area = u32(previous_area_id)
          }
        }
        // Copy the original walkable value regardless of whether we changed it
        // This prevents multiple consecutive non-walkable spans from being erroneously marked as walkable
        previous_was_walkable = walkable
        previous_area_id = u8(span.area)
        previous_span = span
      }
    }
  }
}

// Filter ledge spans
// Mark spans that are ledges as unwalkable
filter_ledge_spans :: proc(
  walkable_height, walkable_climb: int,
  heightfield: ^Heightfield,
) {
  x_size := heightfield.width
  z_size := heightfield.height
  // Mark spans that are adjacent to a ledge as unwalkable
  for z in 0 ..< z_size {
    for x in 0 ..< x_size {
      for span := heightfield.spans[x + z * x_size];
          span != nil;
          span = span.next {
        if span.area == RC_NULL_AREA do continue
        floor := int(span.smax)
        ceiling :=
          span.next != nil ? int(span.next.smin) : MAX_HEIGHTFIELD_HEIGHT
        // The difference between this walkable area and the lowest neighbor walkable area
        lowest_neighbor_floor_difference := MAX_HEIGHTFIELD_HEIGHT
        // Min and max height of accessible neighbors
        lowest_traversable_neighbor_floor := int(span.smax)
        highest_traversable_neighbor_floor := int(span.smax)
        // Check all 4 directions
        for direction in 0 ..< 4 {
          neighbor_x := x + i32(get_dir_offset_x(direction))
          neighbor_z := z + i32(get_dir_offset_y(direction))
          // Skip neighbors which are out of bounds
          if neighbor_x < 0 ||
             neighbor_z < 0 ||
             neighbor_x >= x_size ||
             neighbor_z >= z_size {
            lowest_neighbor_floor_difference = -walkable_climb - 1
            break
          }
          neighbor_span := heightfield.spans[neighbor_x + neighbor_z * x_size]
          // The most we can step down to the neighbor is the walkable_climb distance
          neighbor_ceiling :=
            neighbor_span != nil ? int(neighbor_span.smin) : MAX_HEIGHTFIELD_HEIGHT
          // Skip neighbor if the gap between the spans is too small
          if min(ceiling, neighbor_ceiling) - floor >= walkable_height {
            lowest_neighbor_floor_difference = -walkable_climb - 1
            break
          }
          // For each span in the neighboring column
          for ; neighbor_span != nil; neighbor_span = neighbor_span.next {
            neighbor_floor := int(neighbor_span.smax)
            neighbor_ceiling =
              neighbor_span.next != nil ? int(neighbor_span.next.smin) : MAX_HEIGHTFIELD_HEIGHT
            // Only consider neighboring areas that have enough overlap to be potentially traversable
            if min(ceiling, neighbor_ceiling) - max(floor, neighbor_floor) <
               walkable_height {
              // No space to traverse between them
              continue
            }
            neighbor_floor_difference := neighbor_floor - floor
            lowest_neighbor_floor_difference = min(
              lowest_neighbor_floor_difference,
              neighbor_floor_difference,
            )
            // Find min/max accessible neighbor height
            // Only consider neighbors that are at most walkable_climb away
            if abs(neighbor_floor_difference) <= walkable_climb {
              // There is space to move to the neighbor cell and the slope isn't too much
              lowest_traversable_neighbor_floor = min(
                lowest_traversable_neighbor_floor,
                neighbor_floor,
              )
              highest_traversable_neighbor_floor = max(
                highest_traversable_neighbor_floor,
                neighbor_floor,
              )
            } else if neighbor_floor_difference < -walkable_climb {
              // We already know this will be considered a ledge span so we can early-out
              break
            }
          }
        }
        // The current span is close to a ledge if the magnitude of the drop to any neighbor span
        // is greater than the walkable_climb distance
        if lowest_neighbor_floor_difference < -walkable_climb {
          span.area = RC_NULL_AREA
        } else if highest_traversable_neighbor_floor -
             lowest_traversable_neighbor_floor >
           walkable_climb {
          // If the difference between all neighbor floors is too large, this is a steep slope
          span.area = RC_NULL_AREA
        }
      }
    }
  }
}

// Filter walkable low height spans
// Remove walkable spans without enough clearance
filter_walkable_low_height_spans :: proc(
  walkable_height: int,
  heightfield: ^Heightfield,
) {
  x_size := heightfield.width
  z_size := heightfield.height
  // Remove walkable flag from spans which do not have enough
  // space above them for the agent to stand there
  for z in 0 ..< z_size {
    for x in 0 ..< x_size {
      for span := heightfield.spans[x + z * x_size];
          span != nil;
          span = span.next {
        floor := int(span.smax)
        ceiling :=
          span.next != nil ? int(span.next.smin) : MAX_HEIGHTFIELD_HEIGHT
        if ceiling - floor < walkable_height {
          span.area = RC_NULL_AREA
        }
      }
    }
  }
}

// Apply median filter to walkable area
// Smooths out small inconsistencies in area assignments
median_filter_walkable_area :: proc(chf: ^Compact_Heightfield) -> bool {
  x_size := chf.width
  z_size := chf.height
  areas := make([]u8, len(chf.spans))
  defer delete(areas)
  slice.fill(areas, 0xff)
  for z in 0 ..< z_size {
    for x in 0 ..< x_size {
      cell := &chf.cells[x + z * x_size]
      max_span_index := int(cell.index + u32(cell.count))
      for span_index := int(cell.index);
          span_index < max_span_index;
          span_index += 1 {
        span := &chf.spans[span_index]
        if chf.areas[span_index] == RC_NULL_AREA {
          areas[span_index] = chf.areas[span_index]
          continue
        }
        // Collect neighbor areas
        neighbor_areas: [9]u8
        slice.fill(neighbor_areas[:], chf.areas[span_index])
        // Check all 4 directions
        for dir in 0 ..< 4 {
          if get_con(span, dir) == RC_NOT_CONNECTED {
            continue
          }
          ax := x + get_dir_offset_x(dir)
          az := z + get_dir_offset_y(dir)
          ai := int(chf.cells[ax + az * x_size].index) + get_con(span, dir)
          if chf.areas[ai] != RC_NULL_AREA {
            neighbor_areas[dir * 2 + 0] = chf.areas[ai]
          }
          a_span := &chf.spans[ai]
          dir2 := (dir + 1) & 0x3
          neighbor_connection2 := get_con(a_span, dir2)
          if neighbor_connection2 != RC_NOT_CONNECTED {
            bx := ax + get_dir_offset_x(dir2)
            bz := az + get_dir_offset_y(dir2)
            if bx >= 0 && bx < x_size && bz >= 0 && bz < z_size {
              bi :=
                int(chf.cells[bx + bz * x_size].index) + neighbor_connection2
              if chf.areas[bi] != RC_NULL_AREA {
                neighbor_areas[dir * 2 + 1] = chf.areas[bi]
              }
            }
          }
        }
        // sort and get median
        slice.sort(neighbor_areas[:])
        areas[span_index] = neighbor_areas[4]
      }
    }
  }
  copy(chf.areas, areas)
  return true
}

// Mark all spans within an axis-aligned box with the specified area id
mark_box_area :: proc(
  box_min_bounds, box_max_bounds: [3]f32,
  area_id: u8,
  chf: ^Compact_Heightfield,
) {
  x_size := chf.width
  z_size := chf.height
  // Find the footprint of the box area in grid cell coordinates
  cell_scale := [3]f32{chf.cs, chf.ch, chf.cs}
  min_grid := linalg.floor((box_min_bounds - chf.bmin) / cell_scale)
  max_grid := linalg.floor((box_max_bounds - chf.bmin) / cell_scale)
  // Early-out if the box is outside the bounds of the grid
  if max_grid.x < 0 do return
  if min_grid.x >= f32(x_size) do return
  if max_grid.z < 0 do return
  if min_grid.z >= f32(z_size) do return
  // Clamp relevant bound coordinates to the grid
  min_x := i32(clamp(min_grid.x, 0, f32(x_size) - 1))
  max_x := i32(clamp(max_grid.x, 0, f32(x_size) - 1))
  min_z := i32(clamp(min_grid.z, 0, f32(z_size) - 1))
  max_z := i32(clamp(max_grid.z, 0, f32(z_size) - 1))
  // Mark relevant cells
  for z := min_z; z <= max_z; z += 1 {
    for x := min_x; x <= max_x; x += 1 {
      cell := &chf.cells[x + z * x_size]
      max_span_index := int(cell.index + u32(cell.count))
      for span_index := int(cell.index);
          span_index < max_span_index;
          span_index += 1 {
        span := &chf.spans[span_index]
        // Skip if the span is outside the box extents
        if f32(span.y) < min_grid.y || f32(span.y) > max_grid.y {
          continue
        }
        // Skip if the span has been removed
        if chf.areas[span_index] == RC_NULL_AREA {
          continue
        }
        // Mark the span
        chf.areas[span_index] = area_id
      }
    }
  }
}

// Mark convex polygon area
// Mark all spans within a convex polygon with the specified area id
mark_convex_poly_area :: proc(
  verts: [][3]f32,
  min_y, max_y: f32,
  area_id: u8,
  chf: ^Compact_Heightfield,
) {
  x_size := chf.width
  z_size := chf.height
  // Compute the bounding box of the polygon
  bmin := verts[0]
  bmax := verts[0]
  for v in verts[1:] {
    bmin = linalg.min(bmin, v)
    bmax = linalg.max(bmax, v)
  }
  bmin.y = min_y
  bmax.y = max_y
  // Compute the grid footprint of the polygon
  cell_scale := [3]f32{chf.cs, chf.ch, chf.cs}
  min_grid := linalg.floor((bmin - chf.bmin) / cell_scale)
  max_grid := linalg.floor((bmax - chf.bmin) / cell_scale)
  // Early-out if the polygon lies entirely outside the grid
  if max_grid.x < 0 do return
  if min_grid.x >= f32(x_size) do return
  if max_grid.z < 0 do return
  if min_grid.z >= f32(z_size) do return
  // Clamp the polygon footprint to the grid
  minx := i32(clamp(min_grid.x, 0, f32(x_size) - 1))
  maxx := i32(clamp(max_grid.x, 0, f32(x_size) - 1))
  minz := i32(clamp(min_grid.z, 0, f32(z_size) - 1))
  maxz := i32(clamp(max_grid.z, 0, f32(z_size) - 1))
  // Check each cell in the footprint
  for z := minz; z <= maxz; z += 1 {
    for x := minx; x <= maxx; x += 1 {
      cell := &chf.cells[x + z * x]
      max_span_index := int(cell.index + u32(cell.count))
      for span_index := int(cell.index);
          span_index < max_span_index;
          span_index += 1 {
        span := &chf.spans[span_index]
        // Skip if span is removed
        if chf.areas[span_index] == RC_NULL_AREA {
          continue
        }
        // Skip if y extents don't overlap
        if f32(span.y) < min_grid.y || f32(span.y) > max_grid.y {
          continue
        }
        // Test if cell center is inside the polygon
        point :=
          chf.bmin +
          [3]f32{(f32(x) + 0.5) * chf.cs, 0, (f32(z) + 0.5) * chf.cs}
        if geometry.point_in_polygon_2d(point, verts) {
          chf.areas[span_index] = area_id
        }
      }
    }
  }
}

// Mark all spans within a cylinder with the specified area id
mark_cylinder_area :: proc(
  position: [3]f32,
  radius, height: f32,
  area_id: u8,
  chf: ^Compact_Heightfield,
) {
  x_size := chf.width
  z_size := chf.height
  // Compute the bounding box of the cylinder
  cylinder_bb_min := position - [3]f32{radius, 0, radius}
  cylinder_bb_max := position + [3]f32{radius, height, radius}
  // Compute the grid footprint of the cylinder
  cell_scale := [3]f32{chf.cs, chf.ch, chf.cs}
  min_grid := linalg.floor((cylinder_bb_min - chf.bmin) / cell_scale)
  max_grid := linalg.floor((cylinder_bb_max - chf.bmin) / cell_scale)
  // Early-out if the cylinder is completely outside the grid bounds
  if max_grid.x < 0 do return
  if min_grid.x >= f32(x_size) do return
  if max_grid.z < 0 do return
  if min_grid.z >= f32(z_size) do return
  // Clamp the cylinder bounds to the grid
  minx := i32(clamp(min_grid.x, 0, f32(x_size) - 1))
  maxx := i32(clamp(max_grid.x, 0, f32(x_size) - 1))
  minz := i32(clamp(min_grid.z, 0, f32(z_size) - 1))
  maxz := i32(clamp(max_grid.z, 0, f32(z_size) - 1))
  radius_sq := radius * radius
  for z in minz ..= maxz {
    for x in minx ..= maxx {
      cell := &chf.cells[x + z * x_size]
      max_span_index := int(cell.index + u32(cell.count))
      // Calculate cell center position
      cell_center :=
        chf.bmin + [3]f32{(f32(x) + 0.5) * chf.cs, 0, (f32(z) + 0.5) * chf.cs}
      delta := cell_center - position
      // Skip this column if it's too far from the center point of the cylinder
      if linalg.length2(delta.xz) >= radius_sq {
        continue
      }
      // Mark all overlapping spans
      for span_index in int(cell.index) ..< max_span_index {
        span := &chf.spans[span_index]
        // Skip if span is removed
        if chf.areas[span_index] == RC_NULL_AREA {
          continue
        }
        // Mark if y extents overlap
        if f32(span.y) >= min_grid.y && f32(span.y) <= max_grid.y {
          chf.areas[span_index] = area_id
        }
      }
    }
  }
}
