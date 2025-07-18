package navigation

import "core:log"
import "core:math"

// Calculate grid size from bounds
calc_grid_size :: proc(bmin, bmax: [3]f32, cs: f32) -> (width, height: i32) {
  width = i32((bmax.x - bmin.x) / cs + 0.5)
  height = i32((bmax.z - bmin.z) / cs + 0.5)
  return width, height
}

// Allocate heightfield
alloc_heightfield :: proc() -> ^Heightfield {
  return new(Heightfield)
}

// Create heightfield with bounds
create_heightfield :: proc(hf: ^Heightfield, width, height: i32, bmin, bmax: [3]f32, cs, ch: f32) -> bool {
  if hf == nil do return false
  
  hf.width = width
  hf.height = height
  hf.bmin = bmin
  hf.bmax = bmax
  hf.cs = cs
  hf.ch = ch
  hf.spans = make([]^Span, width * height)
  hf.pools = nil
  hf.freelist = nil
  
  return true
}

// Mark walkable triangles based on slope
mark_walkable_triangles :: proc(walkableSlopeAngle: f32, verts: []f32, tris: []i32, ntris: i32, areas: []u8) {
  walkableThr := math.cos(walkableSlopeAngle * math.PI / 180.0)
  
  for i in 0..<ntris {
    i0 := tris[i*3+0]
    i1 := tris[i*3+1]
    i2 := tris[i*3+2]
    
    v0 := [3]f32{verts[i0*3+0], verts[i0*3+1], verts[i0*3+2]}
    v1 := [3]f32{verts[i1*3+0], verts[i1*3+1], verts[i1*3+2]}
    v2 := [3]f32{verts[i2*3+0], verts[i2*3+1], verts[i2*3+2]}
    
    // Calculate triangle normal
    e0 := v1 - v0
    e1 := v2 - v0
    n := [3]f32{
      e0.y * e1.z - e0.z * e1.y,
      e0.z * e1.x - e0.x * e1.z,
      e0.x * e1.y - e0.y * e1.x,
    }
    
    // Normalize
    len := math.sqrt(n.x*n.x + n.y*n.y + n.z*n.z)
    if len > 0 {
      n.x /= len
      n.y /= len
      n.z /= len
    }
    
    // Check if walkable - but preserve existing NULL_AREA markings
    if areas[i] != NULL_AREA && n.y >= walkableThr {
      areas[i] = WALKABLE_AREA
    } else if areas[i] != NULL_AREA {
      areas[i] = NULL_AREA
    }
    // If areas[i] was already NULL_AREA, leave it as NULL_AREA
  }
}

// Allocate compact heightfield
alloc_compact_heightfield :: proc() -> ^CompactHeightfield {
  return new(CompactHeightfield)
}

// Erode walkable area
erode_walkable_area :: proc(radius: i32, chf: ^CompactHeightfield) -> bool {
  log.debugf("erode_walkable_area: Starting with radius %d", radius)
  w := chf.width
  h := chf.height
  
  if radius <= 0 do return true
  
  // Create a copy of areas for iterative erosion
  areas := make([]u8, chf.span_count)
  defer delete(areas)
  copy(areas, chf.areas)
  
  // Perform radius iterations of erosion
  for iter in 0..<radius {
    eroded := 0
    
    // Copy current state
    copy(areas, chf.areas)
    
    // Erode one layer
    for y in 0..<h {
      for x in 0..<w {
        c := &chf.cells[x + y * w]
        cIndex, cCount := unpack_compact_cell(c.index)
        
        for i in cIndex..<cIndex + u32(cCount) {
          if areas[i] != WALKABLE_AREA do continue
          
          s := &chf.spans[i]
          should_erode := false
          
          // Check if this span is next to a non-walkable area
          for dir in 0..<4 {
            if get_con(s, dir) != NOT_CONNECTED {
              nx := x + get_dir_offset_x(dir)
              ny := y + get_dir_offset_y(dir)
              
              if nx >= 0 && ny >= 0 && nx < w && ny < h {
                nIndex, _ := unpack_compact_cell(chf.cells[nx + ny * w].index)
                ni := nIndex + u32(get_con(s, dir))
                if areas[ni] != WALKABLE_AREA {
                  should_erode = true
                  break
                }
              }
            } else {
              // No connection means edge of mesh or obstacle
              should_erode = true
              break
            }
          }
          
          if should_erode {
            chf.areas[i] = NULL_AREA
            eroded += 1
          }
        }
      }
    }
    
    log.debugf("erode_walkable_area: Iteration %d eroded %d spans", iter, eroded)
    if eroded == 0 do break // No more erosion possible
  }
  
  return true
}

// Allocate polygon mesh
alloc_poly_mesh :: proc() -> ^PolyMesh {
  return new(PolyMesh)
}

// Allocate detail mesh
alloc_poly_mesh_detail :: proc() -> ^PolyMeshDetail {
  return new(PolyMeshDetail)
}

// Free allocated resources
free_heightfield :: proc(hf: ^Heightfield) {
  if hf == nil do return
  
  // Free span pools
  pool := hf.pools
  for pool != nil {
    next := pool.next
    free(pool)
    pool = next
  }
  
  // Free spans array
  delete(hf.spans)
  
  // Free the heightfield itself
  free(hf)
}

// Aliases for compatibility
heightfield_destroy :: free_heightfield
compact_heightfield_destroy :: free_compact_heightfield

// free_compact_heightfield is now defined in compact_heightfield.odin

free_poly_mesh :: proc(mesh: ^PolyMesh) {
  if mesh == nil do return
  delete(mesh.verts)
  delete(mesh.polys)
  delete(mesh.regs)
  delete(mesh.flags)
  delete(mesh.areas)
  free(mesh)
}

free_poly_mesh_detail :: proc(dmesh: ^PolyMeshDetail) {
  if dmesh == nil do return
  delete(dmesh.meshes)
  delete(dmesh.verts)
  delete(dmesh.tris)
  free(dmesh)
}

// Build regions wrapper - actual implementation is in regions.odin

// Build polygon mesh detail
build_poly_mesh_detail :: proc(mesh: ^PolyMesh, chf: ^CompactHeightfield, 
                              sampleDist, sampleMaxError: f32, dmesh: ^PolyMeshDetail) -> bool {
  // TODO: Implement detail mesh generation
  // For now, create a simple detail mesh with one triangle per polygon
  dmesh.n_meshes = mesh.npolys
  dmesh.meshes = make([]u32, dmesh.n_meshes * 4)
  dmesh.n_verts = 0
  dmesh.n_tris = 0
  
  for i in 0..<dmesh.n_meshes {
    dmesh.meshes[i*4+0] = u32(dmesh.n_verts)  // vertBase
    dmesh.meshes[i*4+1] = 0                  // vertCount
    dmesh.meshes[i*4+2] = u32(dmesh.n_tris)   // triBase
    dmesh.meshes[i*4+3] = 0                  // triCount
  }
  
  return true
}