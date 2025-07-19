package tests

import "../mjolnir/navigation"
import "core:log"
import "core:testing"

// Direct test of build_contours function
@(test)
test_build_contours_direct :: proc(t: ^testing.T) {
  // Create a simple square plane
  vertices := [][3]f32{
    {0, 0, 0},
    {5, 0, 0},
    {5, 0, 5},
    {0, 0, 5},
  }
  
  indices := []u32{
    0, 1, 2,
    0, 2, 3,
  }
  
  areas := []u8{
    navigation.WALKABLE_AREA,
    navigation.WALKABLE_AREA,
  }
  
  config := navigation.DEFAULT_CONFIG
  config.cs = 0.3
  config.ch = 0.2
  config.walkable_height = 2
  config.walkable_climb = 1
  config.walkable_radius = 1
  config.min_region_area = 8
  config.merge_region_area = 20
  config.max_simplification_error = 1.3
  config.max_edge_len = 12
  
  // Use the builder to process through heightfield stages
  builder := navigation.builder_init(config)
  defer navigation.builder_destroy(&builder)
  
  input := navigation.Input{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  // Build normally to get intermediate data (bounds calculation happens there)
  navmesh, ok := navigation.build(&builder, &input)
  testing.expect(t, ok, "Navigation mesh should build")
  
  if ok {
    defer navigation.destroy(&navmesh)
    
    // Check if we have debug contours
    if builder.debug_contours != nil {
      cset := builder.debug_contours
      log.infof("Contour debug: Created %d contours", cset.nconts)
      
      // Check contours
      for i in 0..<cset.nconts {
        cont := &cset.conts[i]
        log.infof("  Contour %d: region=%d, nverts=%d, nrverts=%d", 
          i, cont.reg, cont.nverts, cont.nrverts)
        
        // Print first few vertices
        if cont.nverts > 0 && cont.verts != nil {
          log.infof("    First vertex: (%d, %d, %d)", 
            cont.verts[0], cont.verts[1], cont.verts[2])
          if cont.nverts > 1 {
            log.infof("    Second vertex: (%d, %d, %d)", 
              cont.verts[4], cont.verts[5], cont.verts[6])
          }
        }
        
        testing.expect(t, cont.nverts >= 3, 
          "Contour should have at least 3 vertices")
      }
      
      testing.expect(t, cset.nconts > 0, "Should have at least one contour")
    } else {
      log.warn("No debug contours available")
    }
  }
}