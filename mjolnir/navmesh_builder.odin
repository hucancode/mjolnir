package mjolnir

import "core:log"
import "core:strings"
import "core:math/linalg"
import "geometry"
import "navigation"
import "resource"

ExtractContext :: struct {
  warehouse: ^ResourceWarehouse,
  vertices:  ^[dynamic][3]f32,
  indices:   ^[dynamic]u32,
  areas:     ^[dynamic]u8,
}

extract_node_for_navmesh :: proc(node: ^Node, ctx: rawptr) -> bool {
  extract_ctx := cast(^ExtractContext)ctx

  mesh_att, is_mesh := &node.attachment.(MeshAttachment)
  if !is_mesh do return true

  if strings.contains(node.name, "navmesh") || strings.contains(node.name, "collision") {
    mesh := resource.get(extract_ctx.warehouse.meshes, mesh_att.handle)
    if mesh == nil do return true

    world_mat := geometry.transform_get_world_matrix(&node.transform)
    base_idx := u32(len(extract_ctx.vertices))

    for vertex in mesh.geometry_data.vertices {
      world_pos := (world_mat * [4]f32{vertex.position.x, vertex.position.y, vertex.position.z, 1.0}).xyz
      append(extract_ctx.vertices, world_pos)
    }

    for index in mesh.geometry_data.indices {
      append(extract_ctx.indices, index + base_idx)
    }

    for i in 0..<len(mesh.geometry_data.indices)/3 {
      area := u8(navigation.WALKABLE_AREA)
      if strings.contains(node.name, "water") do area = u8(navigation.AREA_WATER)
      if strings.contains(node.name, "door") do area = u8(navigation.AREA_DOOR)
      if strings.contains(node.name, "grass") do area = u8(navigation.AREA_GRASS)
      append(extract_ctx.areas, area)
    }
  }

  return true
}

extract_navmesh_input :: proc(scene: ^Scene, warehouse: ^ResourceWarehouse) -> navigation.NavMeshInput {
  vertices := make([dynamic][3]f32)
  indices := make([dynamic]u32)
  areas := make([dynamic]u8)

  extract_ctx := ExtractContext{
    warehouse = warehouse,
    vertices = &vertices,
    indices = &indices,
    areas = &areas,
  }

  scene_traverse_linear(scene, &extract_ctx, extract_node_for_navmesh)

  return navigation.NavMeshInput{
    vertices = vertices[:],
    indices = indices[:],
    areas = areas[:],
  }
}

// Configuration for navmesh building
NavMeshBuildConfig :: struct {
  cell_size:              f32,    // Voxel size in world units
  cell_height:            f32,    // Voxel height in world units
  agent_height:           f32,    // Agent height in world units
  agent_radius:           f32,    // Agent radius in world units
  agent_max_climb:        f32,    // Max climb height in world units
  agent_max_slope:        f32,    // Max slope angle in degrees
  min_region_area:        i32,    // Minimum region area in voxels
  merge_region_area:      i32,    // Merge region area threshold
  max_edge_length:        f32,    // Max edge length in world units
  max_edge_error:         f32,    // Max edge error in voxels
  max_verts_per_poly:     i32,    // Max vertices per polygon
  detail_sample_dist:     f32,    // Detail mesh sample distance
  detail_sample_max_error: f32,   // Detail mesh max error
}

// Default configuration for typical humanoid agents
default_navmesh_config :: proc() -> NavMeshBuildConfig {
  return NavMeshBuildConfig{
    cell_size = 1.0,
    cell_height = 0.2,
    agent_height = 1.8,
    agent_radius = 0.6,
    agent_max_climb = 0.9,
    agent_max_slope = 45.0,
    min_region_area = 1,
    merge_region_area = 2,
    max_edge_length = 12.0,
    max_edge_error = 1.3,
    max_verts_per_poly = 6,
    detail_sample_dist = 6.0,
    detail_sample_max_error = 1.0,
  }
}

// Build navigation mesh from input mesh data
build_navmesh :: proc(
  input: navigation.NavMeshInput,
  config: NavMeshBuildConfig,
) -> (navmesh: navigation.NavMesh, success: bool) {

  log.info("Building navigation mesh from input data")
  log.infof("NavMeshBuildConfig: cell_size=%.2f, agent_radius=%.2f", config.cell_size, config.agent_radius)

  // Convert build config to navigation config
  nav_config := navigation.Config{
    cs = config.cell_size,
    ch = config.cell_height,
    walkable_slope_angle = config.agent_max_slope,
    walkable_height = i32(config.agent_height / config.cell_height),
    walkable_climb = i32(config.agent_max_climb / config.cell_height),
    walkable_radius = i32(config.agent_radius / config.cell_size),
    max_edge_len = i32(config.max_edge_length / config.cell_size),
    max_simplification_error = config.max_edge_error,
    min_region_area = config.min_region_area,
    merge_region_area = config.merge_region_area,
    max_verts_per_poly = config.max_verts_per_poly,
    detail_sample_dist = config.detail_sample_dist,
    detail_sample_max_error = config.detail_sample_max_error,
  }

  // Calculate bounds from input
  if len(input.vertices) == 0 {
    return navigation.NavMesh{}, false
  }

  bmin := input.vertices[0]
  bmax := input.vertices[0]
  for vertex in input.vertices[1:] {
    bmin = linalg.min(bmin, vertex)
    bmax = linalg.max(bmax, vertex)
  }

  nav_config.bmin = bmin
  nav_config.bmax = bmax

  // Calculate grid size
  nav_config.width = i32((bmax.x - bmin.x) / config.cell_size) + 1
  nav_config.height = i32((bmax.z - bmin.z) / config.cell_size) + 1

  log.infof("Navigation mesh config: grid %dx%d, bounds [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f]",
    nav_config.width, nav_config.height,
    bmin.x, bmin.y, bmin.z,
    bmax.x, bmax.y, bmax.z)

  // Create input for builder
  builder_input := navigation.Input{
    vertices = input.vertices,
    indices = input.indices,
    areas = input.areas,
  }

  // Build navigation mesh using existing builder
  builder := navigation.builder_init(nav_config)
  defer navigation.builder_destroy(&builder)

  return navigation.build(&builder, &builder_input)
}

build_navmesh_from_scene :: proc(scene: ^Scene, warehouse: ^ResourceWarehouse) -> (navigation.NavMesh, bool) {
  input := extract_navmesh_input(scene, warehouse)
  defer {
    delete(input.vertices)
    delete(input.indices)
    delete(input.areas)
  }

  config := default_navmesh_config()
  if len(input.vertices) == 0 {
    log.warn("No vertices extracted from scene")
    return navigation.NavMesh{}, false
  }

  log.infof("Building navmesh from scene: %d vertices, %d triangles",
    len(input.vertices), len(input.indices)/3)

  return build_navmesh(input, config)
}

build_level_navmesh :: proc(scene: ^Scene, warehouse: ^ResourceWarehouse) -> resource.Handle {
  config := navigation.DEFAULT_CONFIG
  config.walkable_radius = 0  // Set small agent size for more walkable area
  log.infof("navmesh_builder: Using walkable_radius = %d", config.walkable_radius)

  input := extract_navmesh_input(scene, warehouse)
  defer {
    delete(input.vertices)
    delete(input.indices)
    delete(input.areas)
  }

  if len(input.vertices) == 0 {
    log.warn("No navigation mesh geometry found in scene")
    return resource.Handle{}
  }

  builder := navigation.builder_init(config)
  defer navigation.builder_destroy(&builder)

  builder_input := navigation.Input{
    vertices = input.vertices,
    indices = input.indices,
    areas = input.areas,
  }

  navmesh, ok := navigation.build(&builder, &builder_input)
  if !ok {
    log.error("Failed to build navigation mesh")
    return resource.Handle{}
  }

  handle, nav_ptr := resource.alloc(&warehouse.navigation_meshes)
  nav_ptr^ = navmesh
  log.infof("Navigation mesh built successfully: %v", ok)

  return handle
}

find_navmesh_path :: proc(warehouse: ^ResourceWarehouse, navmesh_handle: resource.Handle, start, end: [3]f32) -> [][3]f32 {
  navmesh := resource.get(warehouse.navigation_meshes, navmesh_handle)
  if navmesh == nil do return nil

  query := navigation.query_init(navmesh)
  defer navigation.query_deinit(&query)

  path, ok := navigation.find_path(&query, start, end)
  if !ok do return nil

  return path
}
