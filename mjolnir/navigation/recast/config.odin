package recast

import "../../geometry"
import "core:math"
import "core:math/linalg"

// Calculate bounds from vertices
calc_bounds :: proc(verts: [][3]f32) -> (bmin, bmax: [3]f32) {
  if len(verts) == 0 {
    return
  }
  bmin = verts[0]
  bmax = bmin
  for v in verts[1:] {
    bmin = linalg.min(bmin, v)
    bmax = linalg.max(bmax, v)
  }
  return
}

// Calculate grid size from bounds and cell size
calc_grid_size :: proc(bmin, bmax: [3]f32, cs: f32) -> (w, h: i32) {
  w = i32((bmax.x - bmin.x) / cs + 0.5)
  h = i32((bmax.z - bmin.z) / cs + 0.5)
  return
}

// Calculate grid size from config
calc_grid_size_from_config :: proc(cfg: ^Config) -> (width, height: i32) {
  width = i32((cfg.bmax.x - cfg.bmin.x) / cfg.cs + 0.5)
  height = i32((cfg.bmax.z - cfg.bmin.z) / cfg.cs + 0.5)
  return
}

// Validate configuration
validate_config :: proc(cfg: ^Config) -> bool {
  // Check cell sizes
  if cfg.cs <= 0 || cfg.ch <= 0 {
    return false
  }
  // Check bounds (allow zero bounds which indicates they haven't been set yet)
  if cfg.bmin == cfg.bmax && cfg.bmin != {0, 0, 0} {
    return false // Same bounds but not zero (invalid)
  }
  if cfg.bmin.x > cfg.bmax.x ||
     cfg.bmin.y > cfg.bmax.y ||
     cfg.bmin.z > cfg.bmax.z {
    return false // Inverted bounds (invalid)
  }
  // Check agent parameters
  if cfg.walkable_height < 3 {
    return false
  }
  if cfg.walkable_climb < 0 {
    return false
  }
  if cfg.walkable_slope < 0 || cfg.walkable_slope > math.PI * 0.5 {
    return false
  }
  // Check region parameters
  if cfg.min_region_area < 0 || cfg.merge_region_area < 0 {
    return false
  }
  // Check polygon parameters
  if cfg.max_verts_per_poly < 3 {
    return false
  }
  if cfg.max_verts_per_poly > DT_VERTS_PER_POLYGON {
    return false
  }
  return true
}

// Create default configuration
config_create :: proc() -> Config {
  return Config {
    cs = 0.3,
    ch = 0.2,
    walkable_slope = math.PI * 0.25,
    walkable_height = 10,
    walkable_climb = 4,
    walkable_radius = 2,
    max_edge_len = 12,
    max_simplification_error = 1.3,
    min_region_area = 8,
    merge_region_area = 20,
    max_verts_per_poly = 6,
    detail_sample_dist = 6,
    detail_sample_max_error = 1,
    border_size = 0,
    tile_size = 0,
  }
}

// Calculate tile bounds
calc_tile_bounds :: proc(cfg: ^Config, tx, ty: i32) -> (bmin, bmax: [3]f32) {
  bmin = cfg.bmin
  bmax = cfg.bmax
  if cfg.tile_size > 0 {
    ts := f32(cfg.tile_size) * cfg.cs
    bmin.x = cfg.bmin.x + f32(tx) * ts
    bmin.z = cfg.bmin.z + f32(ty) * ts
    bmax.x = cfg.bmin.x + f32(tx + 1) * ts
    bmax.z = cfg.bmin.z + f32(ty + 1) * ts
  }
  return
}

// Get tile count
get_tile_count :: proc(cfg: ^Config) -> (tw, th: i32) {
  if cfg.tile_size <= 0 {
    return 1, 1
  }
  gw, gh := calc_grid_size_from_config(cfg)
  tw = (gw + cfg.tile_size - 1) / cfg.tile_size
  th = (gh + cfg.tile_size - 1) / cfg.tile_size
  return
}

// Calculate walkable threshold from angle
calc_walkable_threshold :: proc(walkable_slope: f32) -> f32 {
  return math.cos(walkable_slope)
}

// Area modification for marking areas
Area_Modification :: struct {
  area_id:   u8,
  mask_type: Area_Mask_Type,
}

Area_Mask_Type :: enum {
  All,
  Walkable,
  Unwalkable,
}

// Convex volume for area marking
Convex_Volume :: struct {
  verts:   [][3]f32,
  hmin:    f32,
  hmax:    f32,
  area_id: u8,
}

// Check if point is inside convex volume
point_in_convex_volume :: proc(pt: [3]f32, vol: ^Convex_Volume) -> bool {
  if pt.y < vol.hmin || pt.y > vol.hmax {
    return false
  }
  return geometry.point_in_polygon_2d(pt, vol.verts)
}
