package navigation

import "core:math"
import "recast"

// NavMeshQuality controls navmesh generation precision vs performance tradeoff
NavMeshQuality :: enum {
  LOW,    // Fast generation, coarse mesh - good for large open areas
  MEDIUM, // Balanced quality and performance - recommended default
  HIGH,   // Higher precision - better for detailed environments
  ULTRA,  // Maximum precision - use for small intricate spaces
}

// NavMeshConfig provides user-friendly agent-centric parameters.
// All Recast internals are derived automatically from quality level.
NavMeshConfig :: struct {
  agent_height:    f32,
  agent_radius:    f32,
  agent_max_climb: f32,
  agent_max_slope: f32,
  quality:         NavMeshQuality,
}

DEFAULT_NAVMESH_CONFIG :: NavMeshConfig {
  agent_height    = 2.0,
  agent_radius    = 0.6,
  agent_max_climb = 0.9,
  agent_max_slope = math.PI * 0.25,
  quality         = .MEDIUM,
}

config_to_recast :: proc(cfg: NavMeshConfig) -> recast.Config {
  cell_size: f32
  cell_height: f32
  min_region_area: i32
  merge_region_area: i32
  max_edge_length: f32
  max_edge_error: f32
  detail_sample_dist: f32
  detail_sample_max_error: f32
  max_verts_per_poly: i32

  switch cfg.quality {
  case .LOW:
    cell_size = cfg.agent_radius * 0.5
    cell_height = cfg.agent_radius * 0.33
    min_region_area = 32
    merge_region_area = 200
    max_edge_length = 20.0
    max_edge_error = 2.0
    detail_sample_dist = 4.0
    detail_sample_max_error = 2.0
    max_verts_per_poly = 4
  case .MEDIUM:
    cell_size = cfg.agent_radius * 0.5
    cell_height = cfg.agent_radius * 0.33
    min_region_area = 64
    merge_region_area = 400
    max_edge_length = 12.0
    max_edge_error = 1.3
    detail_sample_dist = 6.0
    detail_sample_max_error = 1.0
    max_verts_per_poly = 6
  case .HIGH:
    cell_size = cfg.agent_radius * 0.33
    cell_height = cfg.agent_radius * 0.25
    min_region_area = 100
    merge_region_area = 600
    max_edge_length = 8.0
    max_edge_error = 1.0
    detail_sample_dist = 8.0
    detail_sample_max_error = 0.5
    max_verts_per_poly = 6
  case .ULTRA:
    cell_size = cfg.agent_radius * 0.25
    cell_height = cfg.agent_radius * 0.2
    min_region_area = 150
    merge_region_area = 800
    max_edge_length = 6.0
    max_edge_error = 0.8
    detail_sample_dist = 10.0
    detail_sample_max_error = 0.25
    max_verts_per_poly = 6
  }

  return recast.Config {
    cs = cell_size,
    ch = cell_height,
    walkable_slope = cfg.agent_max_slope,
    walkable_height = i32(math.ceil_f32(cfg.agent_height / cell_height)),
    walkable_climb = i32(math.floor_f32(cfg.agent_max_climb / cell_height)),
    walkable_radius = i32(math.ceil_f32(cfg.agent_radius / cell_size)),
    max_edge_len = i32(max_edge_length / cell_size),
    max_simplification_error = max_edge_error,
    min_region_area = min_region_area,
    merge_region_area = merge_region_area,
    max_verts_per_poly = max_verts_per_poly,
    detail_sample_dist = detail_sample_dist * cell_size,
    detail_sample_max_error = detail_sample_max_error * cell_height,
    border_size = 0,
  }
}
