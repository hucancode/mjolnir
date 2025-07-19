package tests

import "core:testing"
import "core:log"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Simple test with just a ground plane (no obstacle)
@(test)
test_simple_ground :: proc(t: ^testing.T) {
  log.info("=== SIMPLE GROUND TEST ===")
  
  // Just 10x10 ground plane
  vertices := [][3]f32{
    {0, 0, 0},   // 0
    {10, 0, 0},  // 1
    {10, 0, 10}, // 2
    {0, 0, 10},  // 3
  }
  
  indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  log.infof("Scene: %d vertices, %d triangles", len(vertices), len(indices)/3)
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  log.info("SUCCESS: Simple ground navmesh built successfully!")
  
  if navmesh.max_tiles > 0 && navmesh.tiles[0].header != nil {
    header := navmesh.tiles[0].header
    log.infof("NavMesh: %d polygons, %d vertices", header.poly_count, header.vert_count)
  }
}