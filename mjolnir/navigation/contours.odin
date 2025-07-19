package navigation

import "core:log"
import "core:math"
import "core:slice"
import "core:math/linalg"
import "../geometry"

// Contour structures moved to recast_types.odin
// Using Contour and ContourSet

build_contours :: proc(chf: ^CompactHeightfield, maxError: f32, maxEdgeLen: i32, cset: ^ContourSet, buildFlags: i32 = CONTOUR_TESS_WALL_EDGES) -> bool {
  w := chf.width
  h := chf.height

  // Initialize edge flags - each span has 4 bits for 4 directions
  flags := make([]u8, chf.span_count)
  defer delete(flags)

  // First pass: Mark boundary edges
  for y in 0..<h {
    for x in 0..<w {
      c := &chf.cells[x + y * w]
      cellIndex, cellCount := unpack_compact_cell(c.index)
      for i in cellIndex..<cellIndex + u32(cellCount) {
        s := &chf.spans[i]
        
        // Skip non-walkable areas and border regions
        if chf.areas[i] == NULL_AREA || s.reg == 0 || (s.reg & BORDER_REG) != 0 {
          flags[i] = 0
          continue
        }
        
        res: u8 = 0
        for dir in 0..<4 {
          r: u16 = 0
          con := get_con(s, dir)
          if con != NOT_CONNECTED {
            nx := x + get_dir_offset_x(dir)
            ny := y + get_dir_offset_y(dir)
            if nx >= 0 && ny >= 0 && nx < w && ny < h {
              nc := &chf.cells[nx + ny * w]
              ncIndex, _ := unpack_compact_cell(nc.index)
              ni := ncIndex + u32(con)
              if ni < u32(chf.span_count) {
                r = chf.spans[ni].reg
              }
            }
          }
          // If neighbor has same region, mark as connected
          if r == s.reg {
            res |= (1 << u8(dir))
          }
        }
        // Invert to mark non-connected edges (boundaries)
        flags[i] = res ~ 0xf
      }
    }
  }

  contours := make([dynamic]Contour)

  log.infof("build_contours: Starting with %d spans", chf.span_count)

  // Debug counts
  boundary_spans := 0
  for i in 0..<chf.span_count {
    if flags[i] != 0 && flags[i] != 0xf {
      boundary_spans += 1
    }
  }
  log.infof("build_contours: Found %d spans with boundary edges", boundary_spans)

  // Track contour generation
  contour_attempts := 0
  regions_with_contours := make(map[u16]bool)
  defer delete(regions_with_contours)

  // Second pass: Trace contours
  for y in 0..<h {
    for x in 0..<w {
      c := &chf.cells[x + y * w]
      cellIndex, cellCount := unpack_compact_cell(c.index)
      for i in cellIndex..<cellIndex + u32(cellCount) {
        // Skip if no boundary edges
        if flags[i] == 0 || flags[i] == 0xf do continue

        area := chf.areas[i]
        reg := chf.spans[i].reg
        if area == NULL_AREA || reg == 0 || (reg & BORDER_REG) != 0 do continue

        contour_attempts += 1

        contour := walk_contour(chf, x, y, i32(i), flags)
        if contour.nrverts < 3 {
          log.debugf("Contour for region %d had only %d raw vertices, skipping", reg, contour.nrverts)
          free_contour(&contour)
          continue
        }

        simplify_contour(&contour, maxError, maxEdgeLen, buildFlags)

        if contour.nverts >= 3 {
          contour.reg = reg
          contour.area = area
          append(&contours, contour)
          regions_with_contours[reg] = true
        } else {
          log.debugf("Contour for region %d had only %d vertices after simplification, skipping", reg, contour.nverts)
          free_contour(&contour)
        }
      }
    }
  }


  // Merge contours
  merge_contours(contours[:], maxError)

  // Fill output contour set
  cset.conts = contours[:]
  cset.nconts = i32(len(contours))
  cset.bmin = chf.bmin
  cset.bmax = chf.bmax
  cset.cs = chf.cs
  cset.ch = chf.ch
  cset.width = chf.width
  cset.height = chf.height
  cset.border_size = chf.border_size
  cset.max_error = maxError

  // Count max region ID
  maxRegionId: u16 = 0
  for i in 0..<chf.span_count {
    if chf.spans[i].reg > maxRegionId {
      maxRegionId = chf.spans[i].reg
    }
  }
  
  log.infof("build_contours: Created %d contours from %d regions", len(contours), maxRegionId)
  log.infof("build_contours: Found %d boundary spans, attempted %d contours", boundary_spans, contour_attempts)
  log.infof("build_contours: %d unique regions have contours", len(regions_with_contours))
  
  // Count contours by region and analyze vertex counts
  region_contour_count := make(map[u16]int)
  defer delete(region_contour_count)
  
  total_vertices := 0
  min_vertices := 999999
  max_vertices := 0
  
  for &contour in contours {
    region_contour_count[contour.reg] += 1
    verts := int(contour.nverts)
    total_vertices += verts
    if verts < min_vertices do min_vertices = verts
    if verts > max_vertices do max_vertices = verts
  }
  
  multi_contour_regions := 0
  for reg, count in region_contour_count {
    if count > 1 {
      multi_contour_regions += 1
    }
  }
  
  if multi_contour_regions > 0 {
    log.debugf("build_contours: %d regions have multiple contours", multi_contour_regions)
  }
  
  if len(contours) > 0 {
    avg_vertices := f32(total_vertices) / f32(len(contours))
    log.debugf("build_contours: Vertex stats - min=%d, max=%d, avg=%.1f", 
      min_vertices, max_vertices, avg_vertices)
  }

  return true
}

// New implementation following Recast's walkContour logic
walk_contour :: proc(chf: ^CompactHeightfield, x, y, i: i32, flags: []u8) -> Contour {
  // Find first non-connected edge
  dir: u8 = 0
  for (flags[i] & (1 << dir)) == 0 {
    dir += 1
    if dir >= 4 {
      return Contour{} // No boundary edges
    }
  }
  
  startDir := dir
  starti := i
  
  area := chf.areas[i]
  
  rawVerts := make([dynamic]i32)
  
  iter := 0
  px, py, pi := x, y, i
  
  for iter < 40000 {
    if (flags[pi] & (1 << dir)) != 0 {
      // This edge is a boundary - add vertex
      isBorderVertex := false
      isAreaBorder := false
      
      // Calculate corner position
      vx := px
      vy := get_corner_height_ext(chf, px, py, pi, int(dir), &isBorderVertex)
      vz := py
      
      // Adjust position based on direction
      switch dir {
      case 0: vz += 1
      case 1: vx += 1; vz += 1  
      case 2: vx += 1
      }
      
      // Get region info
      r: i32 = 0
      s := &chf.spans[pi]
      con := get_con(s, int(dir))
      if con != NOT_CONNECTED {
        ax := px + get_dir_offset_x(int(dir))
        ay := py + get_dir_offset_y(int(dir))
        if ax >= 0 && ay >= 0 && ax < chf.width && ay < chf.height {
          ac := &chf.cells[ax + ay * chf.width]
          acIndex, _ := unpack_compact_cell(ac.index)
          ai := acIndex + u32(con)
          if ai < u32(chf.span_count) {
            r = i32(chf.spans[ai].reg)
            if area != chf.areas[ai] {
              isAreaBorder = true
            }
          }
        }
      }
      
      if isBorderVertex {
        r |= i32(BORDER_VERTEX)
      }
      if isAreaBorder {
        r |= i32(AREA_BORDER)
      }
      
      append(&rawVerts, vx)
      append(&rawVerts, vy)
      append(&rawVerts, vz)
      append(&rawVerts, r)
      
      // Remove visited edge
      flags[pi] &= ~(1 << dir)
      // Rotate CW
      dir = (dir + 1) & 0x3
    } else {
      // Move to neighbor  
      ni: i32 = -1
      nx := px + get_dir_offset_x(int(dir))
      ny := py + get_dir_offset_y(int(dir))
      s := &chf.spans[pi]
      con := get_con(s, int(dir))
      if con != NOT_CONNECTED {
        if nx >= 0 && ny >= 0 && nx < chf.width && ny < chf.height {
          nc := &chf.cells[nx + ny * chf.width]
          ncIndex, _ := unpack_compact_cell(nc.index)
          ni = i32(ncIndex) + i32(con)
        }
      }
      
      if ni == -1 {
        // Should not happen
        break
      }
      
      px = nx
      py = ny
      pi = ni
      // Rotate CCW
      dir = (dir + 3) & 0x3
    }
    
    // Check if we've completed the loop
    if pi == starti && dir == startDir {
      break
    }
    
    iter += 1
  }
  
  return Contour{
    rverts = rawVerts[:],
    nrverts = i32(len(rawVerts)) / 4,
  }
}

// Enhanced corner height calculation with border vertex detection
get_corner_height_ext :: proc(chf: ^CompactHeightfield, x, y, i: i32, dir: int, isBorderVertex: ^bool) -> i32 {
  s := &chf.spans[i]
  ch := i32(s.y)
  dirp := (dir + 1) & 0x3
  
  regs: [4]u32 = {0, 0, 0, 0}
  
  // Combine region and area codes
  regs[0] = u32(chf.spans[i].reg) | (u32(chf.areas[i]) << 16)
  
  // Check neighbor in dir
  con := get_con(s, dir)
  if con != NOT_CONNECTED {
    ax := x + get_dir_offset_x(dir)
    ay := y + get_dir_offset_y(dir)
    if ax >= 0 && ay >= 0 && ax < chf.width && ay < chf.height {
      ac := &chf.cells[ax + ay * chf.width]
      acIndex, _ := unpack_compact_cell(ac.index)
      ai := acIndex + u32(con)
      if ai < u32(chf.span_count) {
        as := &chf.spans[ai]
        ch = max(ch, i32(as.y))
        regs[1] = u32(chf.spans[ai].reg) | (u32(chf.areas[ai]) << 16)
        
        // Check diagonal neighbor
        con2 := get_con(as, dirp)
        if con2 != NOT_CONNECTED {
          ax2 := ax + get_dir_offset_x(dirp)
          ay2 := ay + get_dir_offset_y(dirp)
          if ax2 >= 0 && ay2 >= 0 && ax2 < chf.width && ay2 < chf.height {
            ac2 := &chf.cells[ax2 + ay2 * chf.width]
            acIndex2, _ := unpack_compact_cell(ac2.index)
            ai2 := acIndex2 + u32(con2)
            if ai2 < u32(chf.span_count) {
              as2 := &chf.spans[ai2]
              ch = max(ch, i32(as2.y))
              regs[2] = u32(chf.spans[ai2].reg) | (u32(chf.areas[ai2]) << 16)
            }
          }
        }
      }
    }
  }
  
  // Check neighbor in dirp
  con = get_con(s, dirp)
  if con != NOT_CONNECTED {
    ax := x + get_dir_offset_x(dirp)
    ay := y + get_dir_offset_y(dirp)
    if ax >= 0 && ay >= 0 && ax < chf.width && ay < chf.height {
      ac := &chf.cells[ax + ay * chf.width]
      acIndex, _ := unpack_compact_cell(ac.index)
      ai := acIndex + u32(con)
      if ai < u32(chf.span_count) {
        as := &chf.spans[ai]
        ch = max(ch, i32(as.y))
        regs[3] = u32(chf.spans[ai].reg) | (u32(chf.areas[ai]) << 16)
        
        // Check diagonal neighbor
        con2 := get_con(as, dir)
        if con2 != NOT_CONNECTED {
          ax2 := ax + get_dir_offset_x(dir)
          ay2 := ay + get_dir_offset_y(dir)
          if ax2 >= 0 && ay2 >= 0 && ax2 < chf.width && ay2 < chf.height {
            ac2 := &chf.cells[ax2 + ay2 * chf.width]
            acIndex2, _ := unpack_compact_cell(ac2.index)
            ai2 := acIndex2 + u32(con2)
            if ai2 < u32(chf.span_count) {
              as2 := &chf.spans[ai2]
              ch = max(ch, i32(as2.y))
              regs[2] = u32(chf.spans[ai2].reg) | (u32(chf.areas[ai2]) << 16)
            }
          }
        }
      }
    }
  }
  
  // Check if vertex is special border vertex
  if isBorderVertex != nil {
    for j in 0..<4 {
      a := j
      b := (j + 1) & 0x3
      c := (j + 2) & 0x3
      d := (j + 3) & 0x3
      
      // Check for two same exterior cells followed by two interior cells
      twoSameExts := (regs[a] & regs[b] & u32(BORDER_REG)) != 0 && regs[a] == regs[b]
      twoInts := ((regs[c] | regs[d]) & u32(BORDER_REG)) == 0
      intsSameArea := (regs[c] >> 16) == (regs[d] >> 16)
      noZeros := regs[a] != 0 && regs[b] != 0 && regs[c] != 0 && regs[d] != 0
      
      if twoSameExts && twoInts && intsSameArea && noZeros {
        isBorderVertex^ = true
        break
      }
    }
  }
  
  return ch
}


simplify_contour :: proc(contour: ^Contour, maxError: f32, maxEdgeLen: i32 = 0, buildFlags: i32 = 0) {
  if contour.nrverts < 3 {
    return
  }

  points := contour.rverts
  pn := contour.nrverts
  
  simplified := make([dynamic]i32)
  defer {
    delete(contour.verts)
    contour.verts = simplified[:]
    contour.nverts = i32(len(simplified)) / 4
  }

  // Add initial points
  hasConnections := false
  for i in 0..<pn {
    if (points[i*4+3] & i32(CONTOUR_REG_MASK)) != 0 {
      hasConnections = true
      break
    }
  }
  
  if hasConnections {
    // The contour has some portals to other regions.
    // Add a new point to every location where the region changes.
    for i in 0..<pn {
      ii := (i + 1) % pn
      differentRegs := (points[i*4+3] & i32(CONTOUR_REG_MASK)) != (points[ii*4+3] & i32(CONTOUR_REG_MASK))
      areaBorders := (points[i*4+3] & i32(AREA_BORDER)) != (points[ii*4+3] & i32(AREA_BORDER))
      if differentRegs || areaBorders {
        append(&simplified, points[i*4+0])
        append(&simplified, points[i*4+1])
        append(&simplified, points[i*4+2])
        append(&simplified, i32(i))
      }
    }
  }
  
  if len(simplified) == 0 {
    // If there are no connections at all,
    // create some initial points for the simplification process.
    // Find lower-left and upper-right vertices of the contour.
    llx := points[0]
    lly := points[1]
    llz := points[2]
    lli := i32(0)
    urx := points[0]
    ury := points[1]
    urz := points[2]
    uri := i32(0)
    
    for i in 0..<pn {
      x := points[i*4+0]
      y := points[i*4+1]
      z := points[i*4+2]
      if x < llx || (x == llx && z < llz) {
        llx = x
        lly = y
        llz = z
        lli = i32(i)
      }
      if x > urx || (x == urx && z > urz) {
        urx = x
        ury = y
        urz = z
        uri = i32(i)
      }
    }
    
    append(&simplified, llx)
    append(&simplified, lly)
    append(&simplified, llz)
    append(&simplified, lli)
    
    append(&simplified, urx)
    append(&simplified, ury)
    append(&simplified, urz)
    append(&simplified, uri)
  }
  
  // Add points until all raw points are within
  // error tolerance to the simplified shape.
  for i := 0; i < len(simplified)/4; {
    ii := (i + 1) % (len(simplified)/4)
    
    ax := simplified[i*4+0]
    az := simplified[i*4+2]
    ai := int(simplified[i*4+3])
    
    bx := simplified[ii*4+0]
    bz := simplified[ii*4+2]
    bi := int(simplified[ii*4+3])
    
    // Find maximum deviation from the segment.
    maxd: f32 = 0
    maxi := -1
    ci, cinc, endi: int
    
    // Traverse the segment in lexicographical order
    if bx > ax || (bx == ax && bz > az) {
      cinc = 1
      ci = (ai + cinc) % int(pn)
      endi = bi
    } else {
      cinc = int(pn) - 1
      ci = (bi + cinc) % int(pn)
      endi = ai
      ax, bx = bx, ax
      az, bz = bz, az
    }
    
    // Tessellate only outer edges or edges between areas.
    if (points[ci*4+3] & i32(CONTOUR_REG_MASK)) == 0 ||
       (points[ci*4+3] & i32(AREA_BORDER)) != 0 {
      for ci != endi {
        d := dist_pt_seg_sqr_2d(points[ci*4+0], points[ci*4+2], ax, az, bx, bz)
        if d > maxd {
          maxd = d
          maxi = ci
        }
        ci = (ci + cinc) % int(pn)
      }
    }
    
    // If the max deviation is larger than accepted error,
    // add new point, else continue to next segment.
    if maxi != -1 && maxd > (maxError*maxError) {
      // Insert the point
      insert_at(&simplified, (i+1)*4,
        points[maxi*4+0], points[maxi*4+1], points[maxi*4+2], i32(maxi))
    } else {
      i += 1
    }
  }
  
  // Split too long edges if requested
  if maxEdgeLen > 0 && (buildFlags & (CONTOUR_TESS_WALL_EDGES|CONTOUR_TESS_AREA_EDGES)) != 0 {
    for i := 0; i < len(simplified)/4; {
      ii := (i + 1) % (len(simplified)/4)
      
      ax := simplified[i*4+0]
      az := simplified[i*4+2]
      ai := int(simplified[i*4+3])
      
      bx := simplified[ii*4+0]
      bz := simplified[ii*4+2]
      bi := int(simplified[ii*4+3])
      
      // Find maximum deviation from the segment.
      maxi := -1
      ci := (ai + 1) % int(pn)
      
      // Tessellate only outer edges or edges between areas.
      tess := false
      // Wall edges.
      if (buildFlags & CONTOUR_TESS_WALL_EDGES) != 0 && (points[ci*4+3] & i32(CONTOUR_REG_MASK)) == 0 {
        tess = true
      }
      // Edges between areas.
      if (buildFlags & CONTOUR_TESS_AREA_EDGES) != 0 && (points[ci*4+3] & i32(AREA_BORDER)) != 0 {
        tess = true
      }
      
      if tess {
        dx := bx - ax
        dz := bz - az
        if dx*dx + dz*dz > maxEdgeLen*maxEdgeLen {
          // Round based on the segments in lexicographical order
          n := bi < ai ? (bi + int(pn) - ai) : (bi - ai)
          if n > 1 {
            if bx > ax || (bx == ax && bz > az) {
              maxi = (ai + n/2) % int(pn)
            } else {
              maxi = (ai + (n+1)/2) % int(pn)
            }
          }
        }
      }
      
      // If the max deviation is larger than accepted error,
      // add new point, else continue to next segment.
      if maxi != -1 {
        // Insert the point
        insert_at(&simplified, (i+1)*4,
          points[maxi*4+0], points[maxi*4+1], points[maxi*4+2], i32(maxi))
      } else {
        i += 1
      }
    }
  }
  
  // Store final flags
  for i in 0..<len(simplified)/4 {
    // The edge vertex flag is taken from the current raw point,
    // and the neighbour region is taken from the next raw point.
    ai := (simplified[i*4+3] + 1) % pn
    bi := simplified[i*4+3]
    simplified[i*4+3] = (points[ai*4+3] & (i32(CONTOUR_REG_MASK)|i32(AREA_BORDER))) | (points[bi*4+3] & i32(BORDER_VERTEX))
  }
  
  // Remove degenerate segments
  remove_degenerate_segments(&simplified)
}

// Helper to insert elements into dynamic array
insert_at :: proc(arr: ^[dynamic]i32, index: int, v0, v1, v2, v3: i32) {
  append(arr, v0, v1, v2, v3)
  // Shift elements
  for j := len(arr)-4; j > index; j -= 4 {
    arr[j+0], arr[j+1], arr[j+2], arr[j+3] = arr[j-4], arr[j-3], arr[j-2], arr[j-1]
  }
  arr[index+0] = v0
  arr[index+1] = v1
  arr[index+2] = v2
  arr[index+3] = v3
}

// Remove adjacent vertices which are equal on xz-plane
remove_degenerate_segments :: proc(simplified: ^[dynamic]i32) {
  npts := len(simplified) / 4
  for i := 0; i < npts; {
    ni := (i + 1) % npts
    
    if simplified[i*4+0] == simplified[ni*4+0] && simplified[i*4+2] == simplified[ni*4+2] {
      // Degenerate segment, remove point ni (4 elements)
      for j := ni*4; j < len(simplified)-4; j += 1 {
        simplified[j] = simplified[j+4]
      }
      resize(simplified, len(simplified)-4)
      npts -= 1
    } else {
      i += 1
    }
  }
}

dist_pt_seg_sqr_2d :: proc(px, pz, ax, az, bx, bz: i32) -> f32 {
  dx := f32(bx - ax)
  dz := f32(bz - az)

  if dx*dx + dz*dz > 0.0001 {
    t := (f32(px - ax) * dx + f32(pz - az) * dz) / (dx*dx + dz*dz)
    t = clamp(t, 0, 1)

    proj_x := f32(ax) + t * dx
    proj_z := f32(az) + t * dz

    dx = f32(px) - proj_x
    dz = f32(pz) - proj_z

    return dx*dx + dz*dz
  }

  dx = f32(px - ax)
  dz = f32(pz - az)
  return dx*dx + dz*dz
}

merge_contours :: proc(contours: []Contour, maxError: f32) {
  for i in 0..<len(contours) {
    ca := &contours[i]
    if ca.nverts == 0 do continue

    for j in i+1..<len(contours) {
      cb := &contours[j]
      if cb.nverts == 0 do continue

      if ca.reg != cb.reg || ca.area != cb.area {
        continue
      }

      if can_merge_contours(ca, cb, maxError) {
        merge_contour_pair(ca, cb)
        cb.nverts = 0
      }
    }
  }
}

can_merge_contours :: proc(ca, cb: ^Contour, maxError: f32) -> bool {
  ia, ib := find_contour_connection_points(ca, cb)
  return ia != -1 && ib != -1
}

find_contour_connection_points :: proc(ca, cb: ^Contour) -> (ia, ib: i32) {
  for i in 0..<ca.nverts {
    va_x := ca.verts[i*4 + 0]
    va_z := ca.verts[i*4 + 2]

    for j in 0..<cb.nverts {
      vb_x := cb.verts[j*4 + 0]
      vb_z := cb.verts[j*4 + 2]

      if va_x == vb_x && va_z == vb_z {
        return i, j
      }
    }
  }
  return -1, -1
}

merge_contour_pair :: proc(ca, cb: ^Contour) {
  // TODO: Implement contour merging
}

// Helper function to free contour resources
free_contour :: proc(contour: ^Contour) {
  delete(contour.verts)
  delete(contour.rverts)
}

// Helper to allocate contour set
alloc_contour_set :: proc() -> ^ContourSet {
  return new(ContourSet)
}

// Helper to free contour set
free_contour_set :: proc(cset: ^ContourSet) {
  if cset == nil do return
  for &contour in cset.conts {
    free_contour(&contour)
  }
  delete(cset.conts)
  free(cset)
}

// Build polygon mesh from contours
build_poly_mesh :: proc(cset: ^ContourSet, nvp: i32) -> ^PolyMesh {
  if cset == nil || cset.nconts == 0 do return nil
  
  pmesh := alloc_poly_mesh()
  if pmesh == nil do return nil
  
  pmesh.bmin = cset.bmin
  pmesh.bmax = cset.bmax
  pmesh.cs = cset.cs
  pmesh.ch = cset.ch
  pmesh.border_size = cset.border_size
  pmesh.max_edge_error = cset.max_error
  pmesh.nvp = nvp
  
  // Count vertices and triangles
  max_vertices := 0
  max_tris := 0
  for i in 0..<cset.nconts {
    cont := &cset.conts[i]
    if cont.nverts < 3 do continue
    max_vertices += int(cont.nverts)
    max_tris += int(cont.nverts - 2)
  }
  
  if max_vertices >= 0xfffe {
    log.error("build_poly_mesh: Too many vertices %d", max_vertices)
    free_poly_mesh(pmesh)
    return nil
  }
  
  // Allocate mesh data
  pmesh.verts = make([]u16, max_vertices * 3)
  pmesh.polys = make([]u16, max_tris * int(nvp) * 2)
  pmesh.regs = make([]u16, max_tris)
  pmesh.flags = make([]u16, max_tris)
  pmesh.areas = make([]u8, max_tris)
  pmesh.max_polys = i32(max_tris)
  
  // Initialize polys to 0xffff (RC_MESH_NULL_IDX)
  for i in 0..<len(pmesh.polys) {
    pmesh.polys[i] = 0xffff
  }
  
  // Vertex deduplication hash map
  // Key: (x << 32) | (z << 16) | y
  vertex_map := make(map[u64]i32)
  defer delete(vertex_map)
  
  // Helper function to add a vertex with deduplication
  add_vertex :: proc(pmesh: ^PolyMesh, vertex_map: ^map[u64]i32, x, y, z: i32) -> i32 {
    // Create hash key from vertex position
    key := (u64(x) << 32) | (u64(z) << 16) | u64(y)
    
    // Check if vertex already exists
    if existing_idx, ok := vertex_map[key]; ok {
      return existing_idx
    }
    
    // Add new vertex
    idx := pmesh.nverts
    if idx >= i32(len(pmesh.verts) / 3) {
      log.error("add_vertex: Out of vertex space")
      return -1
    }
    
    v_idx := idx * 3
    pmesh.verts[v_idx + 0] = u16(x)
    pmesh.verts[v_idx + 1] = u16(y)
    pmesh.verts[v_idx + 2] = u16(z)
    pmesh.nverts += 1
    
    // Store in map
    vertex_map[key] = idx
    
    return idx
  }
  
  // Build mesh from contours
  for i in 0..<cset.nconts {
    cont := &cset.conts[i]
    if cont.nverts < 3 do continue
    
    poly_count_before := pmesh.npolys
    
    // Add vertices with deduplication
    vert_indices := make([]i32, cont.nverts)
    defer delete(vert_indices)
    
    for j in 0..<cont.nverts {
      v_idx := j * 4
      x := cont.verts[v_idx + 0]
      y := cont.verts[v_idx + 1]
      z := cont.verts[v_idx + 2]
      
      vert_idx := add_vertex(pmesh, &vertex_map, x, y, z)
      if vert_idx == -1 {
        log.error("build_poly_mesh: Failed to add vertex")
        continue
      }
      vert_indices[j] = vert_idx
    }
    
    // Always triangulate first to get a consistent mesh
    // We'll merge triangles later to optimize polygon count
    log.debugf("Triangulating contour %d with %d vertices", i, cont.nverts)
    
    // Convert vert_indices to u16 array for triangulation
    contour_verts := make([]u16, cont.nverts)
    defer delete(contour_verts)
    for j in 0..<cont.nverts {
      contour_verts[j] = u16(vert_indices[j])
    }
    
    // Triangulate the contour
    triangles := make([dynamic]u16)
    defer delete(triangles)
    
    // Convert pmesh verts from u16 to f32 for triangulation
    verts_f32 := make([]f32, len(pmesh.verts))
    defer delete(verts_f32)
    for v in 0..<len(pmesh.verts) {
      verts_f32[v] = f32(pmesh.verts[v])
    }
    
    ntris := triangulate_polygon(contour_verts, verts_f32, &triangles)
    
    if ntris < 0 {
      log.errorf("Failed to triangulate contour %d with %d vertices", i, cont.nverts)
      // Fall back to simple fan triangulation
      ntris = -ntris
    }
    
    // Add triangles to polygon mesh
    tri_idx := 0
    for t in 0..<ntris {
      if pmesh.npolys >= pmesh.max_polys do break
      
      poly_idx := pmesh.npolys * nvp * 2
      
      // Add triangle vertices
      pmesh.polys[poly_idx + 0] = triangles[tri_idx * 3 + 0]
      pmesh.polys[poly_idx + 1] = triangles[tri_idx * 3 + 1]
      pmesh.polys[poly_idx + 2] = triangles[tri_idx * 3 + 2]
      
      // Fill remaining vertices with null idx
      for k in 3..<nvp {
        pmesh.polys[poly_idx + i32(k)] = 0xffff
      }
      
      // Set region and area
      pmesh.regs[pmesh.npolys] = cont.reg
      pmesh.areas[pmesh.npolys] = cont.area
      
      // Set flags based on area type (matching Detour conventions)
      switch cont.area {
      case u8(WALKABLE_AREA):
        pmesh.flags[pmesh.npolys] = POLYFLAGS_WALK
      case u8(AREA_WATER):
        pmesh.flags[pmesh.npolys] = POLYFLAGS_SWIM
      case u8(AREA_DOOR):
        pmesh.flags[pmesh.npolys] = POLYFLAGS_WALK | POLYFLAGS_DOOR
      case:
        // Other areas get walk flag by default if they're not null
        if cont.area != u8(NULL_AREA) {
          pmesh.flags[pmesh.npolys] = POLYFLAGS_WALK
        } else {
          pmesh.flags[pmesh.npolys] = 0
        }
      }
      
      pmesh.npolys += 1
      tri_idx += 1
    }
    
    log.infof("Triangulated contour %d into %d triangles", i, ntris)
    
    poly_count_after := pmesh.npolys
    
    // Log unique vertices used by this contour
    unique_verts := make(map[i32]bool)
    defer delete(unique_verts)
    for vi in vert_indices {
      unique_verts[vi] = true
    }
    
    log.debugf("build_poly_mesh: Contour %d (region %d) created %d polygons using %d vertices", 
              i, cont.reg, poly_count_after - poly_count_before, len(unique_verts))
  }
  
  // Log vertex deduplication statistics
  total_vertex_attempts := 0
  for i in 0..<cset.nconts {
    cont := &cset.conts[i]
    if cont.nverts >= 3 {
      total_vertex_attempts += int(cont.nverts)
    }
  }
  
  deduplicated_count := total_vertex_attempts - int(pmesh.nverts)
  if deduplicated_count > 0 {
    dedup_ratio := f32(deduplicated_count) / f32(total_vertex_attempts) * 100
    log.infof("build_poly_mesh: Vertex deduplication - %d/%d vertices deduplicated (%.1f%%)", 
              deduplicated_count, total_vertex_attempts, dedup_ratio)
  }
  
  // Build mesh adjacency
  build_mesh_adjacency(pmesh)
  
  // Merge polygons to reduce triangle count - but only if we have enough polygons
  // to maintain connectivity. Don't merge if we'd end up with a single polygon.
  if nvp > 3 && pmesh.npolys > 2 {
    log.infof("Merging polygons to optimize mesh (initial count: %d)", pmesh.npolys)
    initial_count := pmesh.npolys
    merge_polygons(pmesh, nvp)
    log.infof("After merging: %d polygons (reduced by %d)", pmesh.npolys, initial_count - pmesh.npolys)
    
    // If merging reduced us to a single polygon, this destroys connectivity
    if pmesh.npolys == 1 {
      log.warnf("Polygon merging created single polygon - this will cause pathfinding issues")
    }
    
    // Rebuild adjacency after merging
    build_mesh_adjacency(pmesh)
  } else {
    log.infof("Skipping polygon merging: nvp=%d, npolys=%d (need nvp>3 and npolys>2)", nvp, pmesh.npolys)
  }
  
  // Validate polygon connectivity
  disconnected_count := 0
  isolated_polys := make([dynamic]i32)
  defer delete(isolated_polys)
  
  for i in 0..<pmesh.npolys {
    p := i * pmesh.nvp * 2
    has_neighbor := false
    for j in 0..<pmesh.nvp {
      if pmesh.polys[p + j] == 0xffff do break
      if pmesh.polys[p + pmesh.nvp + j] != 0xffff {
        has_neighbor = true
        break
      }
    }
    if !has_neighbor {
      disconnected_count += 1
      if len(isolated_polys) < 10 {  // Track first 10 for debugging
        append(&isolated_polys, i)
      }
    }
  }
  
  if disconnected_count > 0 {
    log.warnf("build_poly_mesh: %d/%d polygons have no neighbors", disconnected_count, pmesh.npolys)
    if len(isolated_polys) > 0 {
      log.debugf("  First isolated polygons: %v", isolated_polys[:])
    }
  }
  
  log.infof("build_poly_mesh: Created %d vertices, %d polygons", pmesh.nverts, pmesh.npolys)
  
  return pmesh
}

// Edge structure for building adjacency (following Recast reference)
MeshEdge :: struct {
  vert: [2]u16,      // Edge vertices  
  poly: [2]u16,      // Polygons using this edge
  poly_edge: [2]u16, // Edge index within each polygon
}

// Build mesh adjacency information using reference Recast algorithm
build_mesh_adjacency :: proc(mesh: ^PolyMesh) -> bool {
  if mesh == nil do return false
  
  nvp := mesh.nvp
  npolys := mesh.npolys
  nverts := mesh.nverts
  
  // Initialize all edges as unconnected
  for i in 0..<npolys {
    p := i * nvp * 2
    for j in 0..<nvp {
      if mesh.polys[p + j] == 0xffff do break
      mesh.polys[p + nvp + j] = 0xffff
    }
  }
  
  max_edge_count := npolys * nvp
  
  // Allocate edge tracking structures
  first_edge := make([]u16, nverts + max_edge_count)
  defer delete(first_edge)
  next_edge := first_edge[nverts:]
  
  edges := make([]MeshEdge, max_edge_count)
  defer delete(edges)
  edge_count := 0
  
  // Initialize first_edge array
  for i in 0..<nverts {
    first_edge[i] = 0xffff
  }
  
  // First pass: Create edges for v0 < v1
  for i in 0..<npolys {
    poly_base := i * nvp * 2
    for j in 0..<nvp {
      if mesh.polys[poly_base + j] == 0xffff do break
      
      v0 := mesh.polys[poly_base + j]
      v1: u16
      if j + 1 >= nvp || mesh.polys[poly_base + j + 1] == 0xffff {
        v1 = mesh.polys[poly_base + 0]
      } else {
        v1 = mesh.polys[poly_base + j + 1]
      }
      
      if v0 < v1 {
        edge := &edges[edge_count]
        edge.vert[0] = v0
        edge.vert[1] = v1  
        edge.poly[0] = u16(i)
        edge.poly_edge[0] = u16(j)
        edge.poly[1] = u16(i)  // Will be updated in second pass
        edge.poly_edge[1] = 0
        
        // Insert edge into linked list
        next_edge[edge_count] = first_edge[v0]
        first_edge[v0] = u16(edge_count)
        edge_count += 1
      }
    }
  }
  
  // Second pass: Find matching edges for v0 > v1  
  for i in 0..<npolys {
    poly_base := i * nvp * 2
    for j in 0..<nvp {
      if mesh.polys[poly_base + j] == 0xffff do break
      
      v0 := mesh.polys[poly_base + j]
      v1: u16
      if j + 1 >= nvp || mesh.polys[poly_base + j + 1] == 0xffff {
        v1 = mesh.polys[poly_base + 0]
      } else {
        v1 = mesh.polys[poly_base + j + 1]
      }
      
      if v0 > v1 {
        // Look for matching edge
        for e := first_edge[v1]; e != 0xffff; e = next_edge[e] {
          edge := &edges[e]
          if edge.vert[1] == v0 && edge.poly[0] == edge.poly[1] {
            edge.poly[1] = u16(i)
            edge.poly_edge[1] = u16(j) 
            break
          }
        }
      }
    }
  }
  
  // Store adjacency information
  successful_connections := 0
  for i in 0..<edge_count {
    edge := &edges[i]
    if edge.poly[0] != edge.poly[1] {
      // Connect the two polygons
      p0_base := i32(edge.poly[0]) * nvp * 2
      p1_base := i32(edge.poly[1]) * nvp * 2
      
      mesh.polys[p0_base + nvp + i32(edge.poly_edge[0])] = edge.poly[1]
      mesh.polys[p1_base + nvp + i32(edge.poly_edge[1])] = edge.poly[0]
      successful_connections += 1
    }
  }
  
  log.infof("build_mesh_adjacency: Reference algorithm stats:")
  log.infof("  Total edges processed: %d", edge_count)
  log.infof("  Successful connections: %d", successful_connections)
  log.infof("  Max possible connections: %d", npolys * nvp)
  
  return true
}


// ===== EAR CLIPPING TRIANGULATION HELPERS =====

// Cross product for 2D vectors (using X,Z plane, ignoring Y)
vcross2 :: proc(p0, p1, p2: [3]f32) -> f32 {
  u1 := p1.x - p0.x
  v1 := p1.z - p0.z
  u2 := p2.x - p0.x
  v2 := p2.z - p0.z
  return u1 * v2 - v1 * u2
}

// Check if point r is on the left side of edge pq
left :: proc(p, q, r: [3]f32) -> bool {
  return vcross2(p, q, r) < 0
}

// Check if point r is on the left side or on edge pq
leftOn :: proc(p, q, r: [3]f32) -> bool {
  return vcross2(p, q, r) <= 0
}

// Check if two line segments properly intersect (not at endpoints)
intersectProp :: proc(a, b, c, d: [3]f32) -> bool {
  // Eliminate improper cases
  if (c.x == a.x && c.z == a.z) || (c.x == b.x && c.z == b.z) ||
     (d.x == a.x && d.z == a.z) || (d.x == b.x && d.z == b.z) {
    return false
  }
  
  return left(a, b, c) != left(a, b, d) && left(c, d, a) != left(c, d, b)
}

// Check if c is inside cone formed by a-b-c (for loose diagonal test)
inConeLoose :: proc(i, j: int, vertices: []u16, verts: []f32) -> bool {
  n := len(vertices)
  a0 := vertices[(i + n - 1) % n]
  a1 := vertices[i]
  a2 := vertices[(i + 1) % n]
  
  pi := [3]f32{
    verts[a1 * 3 + 0],
    verts[a1 * 3 + 1],
    verts[a1 * 3 + 2],
  }
  
  pi1 := [3]f32{
    verts[a0 * 3 + 0],
    verts[a0 * 3 + 1],
    verts[a0 * 3 + 2],
  }
  
  pi2 := [3]f32{
    verts[a2 * 3 + 0],
    verts[a2 * 3 + 1],
    verts[a2 * 3 + 2],
  }
  
  pj := [3]f32{
    verts[vertices[j] * 3 + 0],
    verts[vertices[j] * 3 + 1],
    verts[vertices[j] * 3 + 2],
  }
  
  // If P[i] is a convex vertex
  if leftOn(pi1, pi, pi2) {
    return left(pi, pj, pi1) && left(pj, pi, pi2)
  }
  // Else P[i] is reflex
  return !(leftOn(pi, pj, pi2) && leftOn(pj, pi, pi1))
}

// Check if diagonal i-j is valid (loose version for overlapping segments)
diagonalLoose :: proc(i, j: int, vertices: []u16, verts: []f32) -> bool {
  n := len(vertices)
  d0 := (i + 1) % n
  d1 := (j + 1) % n
  
  // For each edge (k,k+1) not incident to i or j
  for k in 0..<n {
    k1 := (k + 1) % n
    // Skip edges incident to i or j
    if !((k == i) || (k1 == i) || (k == j) || (k1 == j)) {
      p0 := [3]f32{
        verts[vertices[i] * 3 + 0],
        verts[vertices[i] * 3 + 1],
        verts[vertices[i] * 3 + 2],
      }
      p1 := [3]f32{
        verts[vertices[j] * 3 + 0],
        verts[vertices[j] * 3 + 1],
        verts[vertices[j] * 3 + 2],
      }
      p2 := [3]f32{
        verts[vertices[k] * 3 + 0],
        verts[vertices[k] * 3 + 1],
        verts[vertices[k] * 3 + 2],
      }
      p3 := [3]f32{
        verts[vertices[k1] * 3 + 0],
        verts[vertices[k1] * 3 + 1],
        verts[vertices[k1] * 3 + 2],
      }
      
      if intersectProp(p0, p1, p2, p3) {
        return false
      }
    }
  }
  
  return inConeLoose(i, j, vertices, verts)
}

// Triangulate polygon using ear clipping
triangulate_polygon :: proc(vertices: []u16, verts: []f32, triangles: ^[dynamic]u16) -> i32 {
  n := len(vertices)
  if n < 3 do return 0
  if n == 3 {
    append(triangles, vertices[0], vertices[1], vertices[2])
    return 1
  }
  
  // Create index list for triangulation
  indices := make([]int, n)
  defer delete(indices)
  for i in 0..<n do indices[i] = i
  
  ntris: i32 = 0
  vcount := n
  
  // Start with v[1] to match reference
  v := 1
  max_iters := vcount * 10
  
  for vcount > 2 && max_iters > 0 {
    max_iters -= 1
    
    // Try normal diagonal first
    found_ear := false
    min_len: f32 = -1
    mini := -1
    
    for i in 0..<vcount {
      i1 := (i + 1) % vcount
      i2 := (i + 2) % vcount
      
      // Check if this forms a valid diagonal
      if diagonalLoose(indices[i], indices[i2], vertices, verts) {
        // Calculate diagonal length
        p0 := [3]f32{
          verts[vertices[indices[i]] * 3 + 0],
          verts[vertices[indices[i]] * 3 + 1],
          verts[vertices[indices[i]] * 3 + 2],
        }
        p2 := [3]f32{
          verts[vertices[indices[i2]] * 3 + 0],
          verts[vertices[indices[i2]] * 3 + 1],
          verts[vertices[indices[i2]] * 3 + 2],
        }
        
        dx := p2.x - p0.x
        dz := p2.z - p0.z
        len_sqr := dx*dx + dz*dz
        
        // Choose shortest diagonal
        if min_len < 0 || len_sqr < min_len {
          min_len = len_sqr
          mini = i
        }
      }
    }
    
    if mini != -1 {
      // Found valid ear, clip it
      i := mini
      i1 := (i + 1) % vcount
      i2 := (i + 2) % vcount
      
      append(triangles, vertices[indices[i]], vertices[indices[i1]], vertices[indices[i2]])
      ntris += 1
      
      // Remove vertex i1 from the list
      for k in i1..<vcount-1 {
        indices[k] = indices[k+1]
      }
      vcount -= 1
      
      // Update position
      v = (i1 >= vcount) ? 0 : i1
    } else {
      // No valid ear found - should not happen with valid input
      log.warnf("triangulate_polygon: Failed to find valid ear, %d vertices remaining", vcount)
      return -ntris
    }
  }
  
  return ntris
}

// Count vertices in polygon (up to first 0xffff)
count_poly_verts :: proc(poly: []u16, nvp: i32) -> i32 {
  for i in 0..<nvp {
    if poly[i] == 0xffff do return i
  }
  return nvp
}

// Check if vertex ordering forms a left turn (for convexity check)
uleft :: proc(verts: []u16, a, b, c: u16) -> bool {
  ax := i32(verts[a*3])
  ay := i32(verts[a*3+2])
  bx := i32(verts[b*3])
  by := i32(verts[b*3+2])
  cx := i32(verts[c*3])
  cy := i32(verts[c*3+2])
  
  return ((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) < 0
}

// Get the merge value for two polygons
get_poly_merge_value :: proc(verts: []u16, pa, pb: []u16, nvp: i32) -> (value: i32, ea, eb: i32) {
  na := count_poly_verts(pa, nvp)
  nb := count_poly_verts(pb, nvp)
  
  // If merged polygon would be too big, cannot merge
  if na + nb - 2 > nvp do return -1, -1, -1
  
  // Check if polygons share an edge
  ea = -1
  eb = -1
  
  for i in 0..<na {
    va0 := pa[i]
    va1 := pa[(i+1) % na]
    if va0 > va1 {
      va0, va1 = va1, va0
    }
    
    for j in 0..<nb {
      vb0 := pb[j]
      vb1 := pb[(j+1) % nb]
      if vb0 > vb1 {
        vb0, vb1 = vb1, vb0
      }
      
      if va0 == vb0 && va1 == vb1 {
        ea = i32(i)
        eb = i32(j)
        break
      }
    }
    
    if ea != -1 do break
  }
  
  // No common edge
  if ea == -1 || eb == -1 do return -1, -1, -1
  
  // Check if merged polygon would be convex
  // Check vertex before shared edge on pa with vertex after shared edge on pb
  va := pa[(ea + na - 1) % na]
  vb := pa[ea]
  vc := pb[(eb + 2) % nb]
  if !uleft(verts, va, vb, vc) do return -1, -1, -1
  
  // Check vertex before shared edge on pb with vertex after shared edge on pa
  va = pb[(eb + nb - 1) % nb]
  vb = pb[eb]
  vc = pa[(ea + 2) % na]
  if !uleft(verts, va, vb, vc) do return -1, -1, -1
  
  // Calculate merge value (squared length of shared edge)
  va = pa[ea]
  vb = pa[(ea + 1) % na]
  
  dx := i32(verts[va*3]) - i32(verts[vb*3])
  dy := i32(verts[va*3+2]) - i32(verts[vb*3+2])
  
  return dx*dx + dy*dy, ea, eb
}

// Merge two polygons
merge_poly_verts :: proc(pa, pb: []u16, ea, eb: i32, nvp: i32) {
  na := count_poly_verts(pa, nvp)
  nb := count_poly_verts(pb, nvp)
  
  // Temporary buffer for merged result
  tmp := make([]u16, nvp)
  defer delete(tmp)
  for i in 0..<nvp do tmp[i] = 0xffff
  
  n := 0
  // Add vertices from pa, skipping the shared edge
  for i in 0..<na-1 {
    tmp[n] = pa[(ea+1+i) % na]
    n += 1
  }
  // Add vertices from pb, skipping the shared edge  
  for i in 0..<nb-1 {
    tmp[n] = pb[(eb+1+i) % nb]
    n += 1
  }
  
  // Copy back to pa
  for i in 0..<nvp {
    pa[i] = tmp[i]
  }
}

// Merge polygons in the mesh to reduce triangle count
merge_polygons :: proc(mesh: ^PolyMesh, nvp: i32) {
  if mesh == nil || mesh.npolys == 0 do return
  
  max_iterations := mesh.npolys * mesh.npolys  // Safety limit
  
  for iter in 0..<max_iterations {
    // Find best merge candidate
    best_merge_val := i32(0)
    best_pa := i32(-1)
    best_pb := i32(-1) 
    best_ea := i32(-1)
    best_eb := i32(-1)
    
    for i in 0..<mesh.npolys-1 {
      pa_idx := i * nvp * 2
      pa := mesh.polys[pa_idx:pa_idx+nvp]
      
      for j in i+1..<mesh.npolys {
        pb_idx := j * nvp * 2
        pb := mesh.polys[pb_idx:pb_idx+nvp]
        
        // Only merge if regions match
        if mesh.regs[i] != mesh.regs[j] do continue
        
        val, ea, eb := get_poly_merge_value(mesh.verts, pa, pb, nvp)
        if val > best_merge_val {
          best_merge_val = val
          best_pa = i
          best_pb = j
          best_ea = ea
          best_eb = eb
        }
      }
    }
    
    // If no good merge found, we're done
    if best_merge_val <= 0 do break
    
    // Merge the polygons
    pa_idx := best_pa * nvp * 2
    pb_idx := best_pb * nvp * 2
    pa := mesh.polys[pa_idx:pa_idx+nvp]
    pb := mesh.polys[pb_idx:pb_idx+nvp]
    
    merge_poly_verts(pa, pb, best_ea, best_eb, nvp)
    
    // Move last polygon to position of merged polygon
    last_idx := (mesh.npolys - 1) * nvp * 2
    if pb_idx != last_idx {
      // Copy polygon data
      for k in 0..<nvp*2 {
        mesh.polys[pb_idx + k] = mesh.polys[last_idx + k]
      }
      // Copy metadata
      mesh.regs[best_pb] = mesh.regs[mesh.npolys - 1]
      mesh.areas[best_pb] = mesh.areas[mesh.npolys - 1]
      mesh.flags[best_pb] = mesh.flags[mesh.npolys - 1]
    }
    
    mesh.npolys -= 1
    
    if iter % 100 == 0 && iter > 0 {
      log.debugf("Polygon merging progress: %d merges completed, %d polygons remaining", iter, mesh.npolys)
    }
  }
}
