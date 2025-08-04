package navigation_recast


import "core:log"
import "core:math"
import "core:slice"

// Layer constants
RC_MAX_LAYER_ID :: 255
RC_NULL_LAYER_ID :: 255

// Allocate heightfield layer set
alloc_heightfield_layer_set :: proc() -> [dynamic]Heightfield_Layer {
  lset := make([dynamic]Heightfield_Layer)
  return lset
}

// Free heightfield layer set
free_heightfield_layer_set :: proc(lset: [dynamic]Heightfield_Layer) {
  for layer in lset {
    delete(layer.heights)
    delete(layer.areas)
    delete(layer.cons)
  }
  delete(lset)
}

// Build heightfield layers from compact heightfield
build_heightfield_layers :: proc(
  chf: ^Compact_Heightfield,
  border_size: i32,
  walkable_height: i32,
) -> (
  lset: [dynamic]Heightfield_Layer
) {
  if chf == nil do return

  w := chf.width
  h := chf.height

  log.infof("Building heightfield layers from %dx%d compact heightfield", w, h)

  lset = make([dynamic]Heightfield_Layer, 0, 32)

  // Create layer ID array - tracks which layer each span belongs to
  layer_ids := make([]u8, chf.span_count)
  defer delete(layer_ids)
  slice.fill(layer_ids, RC_NULL_LAYER_ID)

  // Assign layer IDs to spans
  if !assign_layer_ids(chf, layer_ids[:]) {
    log.error("Failed to assign layer IDs")
    return
  }

  // Count layers
  max_layer_id: u8 = 0
  for lid in layer_ids {
    if lid != RC_NULL_LAYER_ID {
      max_layer_id = max(max_layer_id, lid)
    }
  }

  if max_layer_id == 0 {
    log.warn("No layers found")
    return
  }

  layer_count := int(max_layer_id) + 1
  log.infof("Found %d layers to build", layer_count)

  // Build each layer
  for layer_id in 0 ..< layer_count {
    if !build_single_layer(
      chf,
      layer_ids[:],
      u8(layer_id),
      border_size,
      walkable_height,
      &lset,
    ) {
      log.warnf("Failed to build layer %d", layer_id)
      continue
    }
  }

  log.infof("Successfully built %d heightfield layers", len(lset))
  return
}

// Assign layer IDs to spans based on height ranges
assign_layer_ids :: proc(
  chf: ^Compact_Heightfield,
  layer_ids: []u8,
) -> bool {
  w := chf.width
  h := chf.height

  // Simple layer assignment based on height ranges
  // For overlapping geometry, we'd need more sophisticated algorithms

  current_layer_id: u8 = 0

  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]

      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(chf.spans)) || i >= u32(len(layer_ids)) {
          continue
        }

        s := &chf.spans[i]

        // Skip non-walkable spans
        if i >= u32(len(chf.areas)) || chf.areas[i] == RC_NULL_AREA {
          continue
        }

        // For now, assign all spans to layer 0
        // In a full implementation, we'd analyze height overlaps
        layer_ids[i] = 0
      }
    }
  }

  return true
}

// Build a single layer from the compact heightfield
build_single_layer :: proc(
  chf: ^Compact_Heightfield,
  layer_ids: []u8,
  layer_id: u8,
  border_size: i32,
  walkable_height: i32,
  layers: ^[dynamic]Heightfield_Layer,
) -> bool {
  w := chf.width
  h := chf.height

  // Find bounds of this layer
  minx := i32(w)
  maxx := i32(0)
  miny := i32(h)
  maxy := i32(0)
  hmin := i32(0xffff)
  hmax := i32(0)

  span_count := 0

  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]

      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(layer_ids)) || layer_ids[i] != layer_id {
          continue
        }

        if i >= u32(len(chf.spans)) {
          continue
        }

        s := &chf.spans[i]

        minx = min(minx, i32(x))
        maxx = max(maxx, i32(x))
        miny = min(miny, i32(y))
        maxy = max(maxy, i32(y))
        hmin = min(hmin, i32(s.y))
        hmax = max(hmax, i32(s.y) + i32(s.h))
        span_count += 1
      }
    }
  }

  if span_count == 0 {
    return false
  }

  // Expand bounds by border size
  minx = max(i32(0), minx - border_size)
  maxx = min(i32(w) - 1, maxx + border_size)
  miny = max(i32(0), miny - border_size)
  maxy = min(i32(h) - 1, maxy + border_size)

  layer_width := maxx - minx + 1
  layer_height := maxy - miny + 1

  if layer_width <= 0 || layer_height <= 0 {
    return false
  }

  log.debugf(
    "Layer %d bounds: (%d,%d) to (%d,%d), size %dx%d, height range %d-%d",
    layer_id,
    minx,
    miny,
    maxx,
    maxy,
    layer_width,
    layer_height,
    hmin,
    hmax,
  )

  // Create layer
  layer := Heightfield_Layer {
    bmin    = chf.bmin,
    bmax    = chf.bmax,
    cs      = chf.cs,
    ch      = chf.ch,
    width   = layer_width,
    height  = layer_height,
    minx    = minx,
    maxx    = maxx,
    miny    = miny,
    maxy    = maxy,
    hmin    = hmin,
    hmax    = hmax,
    heights = make([]u8, int(layer_width * layer_height)),
    areas   = make([]u8, int(layer_width * layer_height)),
    cons    = make([]u8, int(layer_width * layer_height)),
  }

  // Initialize arrays
  slice.fill(layer.heights, 0xff) // No height data
  slice.fill(layer.areas, RC_NULL_AREA)
  slice.fill(layer.cons, 0)

  // Fill layer data
  for y in miny ..= maxy {
    for x in minx ..= maxx {
      c := &chf.cells[x + y * w]

      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(layer_ids)) || layer_ids[i] != layer_id {
          continue
        }

        if i >= u32(len(chf.spans)) || i >= u32(len(chf.areas)) {
          continue
        }

        s := &chf.spans[i]
        lx := x - minx
        ly := y - miny
        lidx := lx + ly * layer_width

        if lidx < 0 || lidx >= i32(len(layer.heights)) {
          continue
        }

        // Store relative height (clamped to 8-bit)
        relative_height := i32(s.y) - hmin
        layer.heights[lidx] = u8(math.clamp(int(relative_height), 0, 255))
        layer.areas[lidx] = chf.areas[i]

        // Build connections (simplified)
        cons: u8 = 0
        for dir in 0 ..< 4 {
          if get_con(s, dir) != RC_NOT_CONNECTED {
            ax := x + get_dir_offset_x(dir)
            ay := y + get_dir_offset_y(dir)

            if ax >= minx && ax <= maxx && ay >= miny && ay <= maxy {
              cons |= u8(1 << u8(dir))
            }
          }
        }
        layer.cons[lidx] = cons
      }
    }
  }

  append(layers, layer)
  return true
}

// Get height value from layer at given coordinates
get_layer_height :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return 0xff
  }

  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.heights)) {
    return 0xff
  }

  return layer.heights[idx]
}

// Get area ID from layer at given coordinates
get_layer_area :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return RC_NULL_AREA
  }

  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.areas)) {
    return RC_NULL_AREA
  }

  return layer.areas[idx]
}

// Get connection info from layer at given coordinates
get_layer_connection :: proc(
  layer: ^Heightfield_Layer,
  x, y: i32,
) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return 0
  }

  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.cons)) {
    return 0
  }

  return layer.cons[idx]
}

// Advanced layer assignment for overlapping geometry
assign_layer_ids_advanced :: proc(
  chf: ^Compact_Heightfield,
  layer_ids: []u8,
) -> bool {
  w := chf.width
  h := chf.height

  // Mark all spans as unassigned initially
  slice.fill(layer_ids, RC_NULL_LAYER_ID)

  current_layer_id: u8 = 0
  layer_regions := make(map[u16]u8) // Map region ID to layer ID
  defer delete(layer_regions)

  // Process each span to detect overlapping regions
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]

      SpanInfo :: struct {
          idx:  u32,
          span: ^Compact_Span,
      }
      // Collect spans in this column
      column_spans := make([dynamic]SpanInfo, 0, c.count)
      defer delete(column_spans)

      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(chf.spans)) || i >= u32(len(chf.areas)) {
          continue
        }

        if chf.areas[i] == RC_NULL_AREA {
          continue
        }

        append(&column_spans, SpanInfo{idx = i, span = &chf.spans[i]})
      }

      if len(column_spans) == 0 {
        continue
      }

      // Sort spans by height
      slice.sort_by(column_spans[:], proc(a, b: SpanInfo) -> bool {
        return a.span.y < b.span.y
      })

      // Assign layer IDs based on vertical separation
      for span_info, i in column_spans {
        span_idx := span_info.idx
        span := span_info.span

        if layer_ids[span_idx] != RC_NULL_LAYER_ID {
          continue // Already assigned
        }

        // Check if this span overlaps with any spans below it
        overlaps_below := false
        if i > 0 {
          prev_span := column_spans[i - 1].span
          prev_top := int(prev_span.y) + int(prev_span.h)
          curr_bottom := int(span.y)

          // If gap is less than walkable height, they're in the same layer
          if curr_bottom - prev_top < int(chf.walkable_height) {
            overlaps_below = true
            layer_ids[span_idx] = layer_ids[column_spans[i - 1].idx]
          }
        }

        if !overlaps_below {
          // Start new layer if needed
          region_id := span.reg
          if region_id in layer_regions {
            layer_ids[span_idx] = layer_regions[region_id]
          } else {
            layer_regions[region_id] = current_layer_id
            layer_ids[span_idx] = current_layer_id
            current_layer_id += 1

            if current_layer_id >= RC_MAX_LAYER_ID {
              log.warnf("Reached maximum layer limit (%d)", RC_MAX_LAYER_ID)
              current_layer_id = RC_MAX_LAYER_ID - 1
            }
          }
        }
      }
    }
  }

  log.infof("Assigned spans to %d layers", current_layer_id)
  return true
}

// Validate layer set integrity
validate_layer_set :: proc(lset: [dynamic]Heightfield_Layer) -> bool {
  if len(lset) == 0 do return false

  for layer, i in lset {
    // Check bounds
    if layer.width <= 0 || layer.height <= 0 {
      log.errorf(
        "Layer %d has invalid dimensions: %dx%d",
        i,
        layer.width,
        layer.height,
      )
      return false
    }

    expected_size := int(layer.width * layer.height)
    if len(layer.heights) != expected_size ||
       len(layer.areas) != expected_size ||
       len(layer.cons) != expected_size {
      log.errorf("Layer %d has mismatched array sizes", i)
      return false
    }

    // Check coordinate bounds
    if layer.minx > layer.maxx || layer.miny > layer.maxy {
      log.errorf("Layer %d has invalid coordinate bounds", i)
      return false
    }
  }

  return true
}
