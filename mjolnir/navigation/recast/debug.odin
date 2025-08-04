package navigation_recast

import "core:log"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

// Debug mesh export utilities for Recast navigation data

// Debug visualization structures
Heightfield_Debug_Vertex :: struct {
    position: [3]f32,
    color: [4]f32,
}

Heightfield_Debug_Mesh :: struct {
    vertices: [dynamic]Heightfield_Debug_Vertex,
    indices: [dynamic]u32,
}

// Debug colors
DEBUG_COLOR_WALKABLE :: [4]f32{0.0, 1.0, 0.0, 0.5}      // Green for walkable
DEBUG_COLOR_OBSTACLE :: [4]f32{1.0, 0.0, 0.0, 0.5}      // Red for obstacles
DEBUG_COLOR_NULL :: [4]f32{0.5, 0.5, 0.5, 0.3}          // Gray for null areas
DEBUG_COLOR_EDGE :: [4]f32{1.0, 1.0, 0.0, 0.8}          // Yellow for connection indicators

// Export polygon mesh to OBJ format
dump_poly_mesh_to_obj :: proc(pmesh: ^Poly_Mesh, filepath: string) -> bool {
    if pmesh == nil || len(pmesh.verts) == 0 || pmesh.npolys == 0 do return false

    log.infof("Exporting polygon mesh to OBJ: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create OBJ file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Navigation Polygon Mesh\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, fmt.tprintf("# Vertices: %d, Polygons: %d\n", len(pmesh.verts), pmesh.npolys))
    os.write_string(file, "\n")

    // Write vertices
    for v in pmesh.verts {
        x := f32(v[0]) * pmesh.cs + pmesh.bmin[0]
        y := f32(v[1]) * pmesh.ch + pmesh.bmin[1]
        z := f32(v[2]) * pmesh.cs + pmesh.bmin[2]

        os.write_string(file, fmt.tprintf("v %.6f %.6f %.6f\n", x, y, z))
    }

    os.write_string(file, "\n")

    // Write faces
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2

        // Count vertices in this polygon
        nverts := 0
        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                nverts += 1
            } else {
                break
            }
        }

        if nverts < 3 do continue

        // Write face (OBJ uses 1-based indexing)
        os.write_string(file, "f")
        for j in 0..<nverts {
            vert_idx := int(pmesh.polys[pi + j]) + 1
            os.write_string(file, fmt.tprintf(" %d", vert_idx))
        }
        os.write_string(file, "\n")
    }

    log.infof("Successfully exported polygon mesh to: %s", filepath)
    return true
}

// Export detail mesh to OBJ format
dump_detail_mesh_to_obj :: proc(dmesh: ^Poly_Mesh_Detail, filepath: string) -> bool {
    if dmesh == nil || len(dmesh.verts) == 0 || len(dmesh.tris) == 0 do return false

    log.infof("Exporting detail mesh to OBJ: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create OBJ file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Navigation Detail Mesh\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, fmt.tprintf("# Vertices: %d, Triangles: %d, Sub-meshes: %d\n",
                    len(dmesh.verts), len(dmesh.tris), len(dmesh.meshes)))
    os.write_string(file, "\n")

    // Write vertices
    for v in dmesh.verts {
        os.write_string(file, fmt.tprintf("v %.6f %.6f %.6f\n", v.x, v.y, v.z))
    }

    os.write_string(file, "\n")

    // Write triangular faces
    for tri in dmesh.tris {
        v1 := int(tri[0]) + 1  // OBJ uses 1-based indexing
        v2 := int(tri[1]) + 1
        v3 := int(tri[2]) + 1
        // tri[3] is area ID

        os.write_string(file, fmt.tprintf("f %d %d %d\n", v1, v2, v3))
    }

    log.infof("Successfully exported detail mesh to: %s", filepath)
    return true
}

// Export contour set to a simple text format for debugging
dump_contour_set :: proc(cset: ^Contour_Set, filepath: string) -> bool {
    if cset == nil || len(cset.conts) == 0 do return false

    log.infof("Exporting contour set to file: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create contour file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Navigation Contour Set\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, fmt.tprintf("# Contours: %d\n", len(cset.conts)))
    os.write_string(file, fmt.tprintf("# Bounds: (%.3f,%.3f,%.3f) to (%.3f,%.3f,%.3f)\n",
                    cset.bmin.x, cset.bmin.y, cset.bmin.z,
                    cset.bmax.x, cset.bmax.y, cset.bmax.z))
    os.write_string(file, fmt.tprintf("# Cell size: %.3f, Cell height: %.3f\n", cset.cs, cset.ch))
    os.write_string(file, "\n")

    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]

        os.write_string(file, fmt.tprintf("# Contour %d\n", i))
        os.write_string(file, fmt.tprintf("# Vertices: %d, Raw vertices: %d\n", len(cont.verts), len(cont.rverts)))
        os.write_string(file, fmt.tprintf("# Region: %d, Area: %d\n", cont.reg, cont.area))
        os.write_string(file, "\n")

        // Write simplified contour vertices
        os.write_string(file, "simplified_vertices:\n")
        for v in cont.verts {
            x := f32(v.x) * cset.cs + cset.bmin.x
            y := f32(v.y) * cset.ch + cset.bmin.y
            z := f32(v.z) * cset.cs + cset.bmin.z
            flags := v.w
            os.write_string(file, fmt.tprintf("  %.6f %.6f %.6f %d\n", x, y, z, flags))
        }

        // Write raw contour vertices
        os.write_string(file, "raw_vertices:\n")
        for v in cont.rverts {
            x := f32(v.x) * cset.cs + cset.bmin.x
            y := f32(v.y) * cset.ch + cset.bmin.y
            z := f32(v.z) * cset.cs + cset.bmin.z
            flags := v.w
            os.write_string(file, fmt.tprintf("  %.6f %.6f %.6f %d\n", x, y, z, flags))
        }

        os.write_string(file, "\n")
    }

    log.infof("Successfully exported contour set to: %s", filepath)
    return true
}

// Export compact heightfield to a text format for debugging
dump_compact_heightfield :: proc(chf: ^Compact_Heightfield, filepath: string) -> bool {
    if chf == nil do return false

    log.infof("Exporting compact heightfield to file: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create heightfield file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Navigation Compact Heightfield\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, fmt.tprintf("# Dimensions: %dx%d\n", chf.width, chf.height))
    os.write_string(file, fmt.tprintf("# Span count: %d\n", chf.span_count))
    os.write_string(file, fmt.tprintf("# Bounds: (%.3f,%.3f,%.3f) to (%.3f,%.3f,%.3f)\n",
                    chf.bmin.x, chf.bmin.y, chf.bmin.z,
                    chf.bmax.x, chf.bmax.y, chf.bmax.z))
    os.write_string(file, fmt.tprintf("# Cell size: %.3f, Cell height: %.3f\n", chf.cs, chf.ch))
    os.write_string(file, fmt.tprintf("# Walkable height: %d, Walkable climb: %d\n",
                    chf.walkable_height, chf.walkable_climb))
    os.write_string(file, fmt.tprintf("# Max distance: %d, Max regions: %d\n",
                    chf.max_distance, chf.max_regions))
    os.write_string(file, "\n")

    // Write cell information
    os.write_string(file, "# Cell data (x, z, span_index, span_count)\n")
    for z in 0..<chf.height {
        for x in 0..<chf.width {
            c := &chf.cells[x + z * chf.width]
            if c.count > 0 {
                os.write_string(file, fmt.tprintf("cell %d %d %d %d\n", x, z, c.index, c.count))
            }
        }
    }

    os.write_string(file, "\n")

    // Write span information (sample, not all to avoid huge files)
    os.write_string(file, "# Span data (span_index, y, height, area, region, connections)\n")
    sample_count := min(1000, int(chf.span_count))  // Limit output size
    for i in 0..<sample_count {
        s := &chf.spans[i]
        area := chf.areas != nil && i < len(chf.areas) ? chf.areas[i] : 0

        // Format connections
        conn_str := strings.builder_make(0, 32)
        defer strings.builder_destroy(&conn_str)

        for dir in 0..<4 {
            conn := get_con(s, dir)
            if conn != RC_NOT_CONNECTED {
                if strings.builder_len(conn_str) > 0 {
                    strings.write_string(&conn_str, ",")
                }
                fmt.sbprintf(&conn_str, "%d:%d", dir, conn)
            }
        }

        os.write_string(file, fmt.tprintf("span %d %d %d %d %d [%s]\n",
                        i, s.y, s.h, area, s.reg, strings.to_string(conn_str)))
    }

    if sample_count < int(chf.span_count) {
        os.write_string(file, fmt.tprintf("# ... (%d more spans not shown)\n",
                        int(chf.span_count) - sample_count))
    }

    log.infof("Successfully exported compact heightfield to: %s", filepath)
    return true
}

// Export heightfield layer set for multi-level geometry debugging
dump_heightfield_layers :: proc(lset: [dynamic]Heightfield_Layer, filepath: string) -> bool {
    if len(lset) == 0 do return false

    log.infof("Exporting heightfield layer set to file: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create layer file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Navigation Heightfield Layer Set\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, fmt.tprintf("# Layers: %d\n", len(lset)))
    os.write_string(file, "\n")

    for i in 0..<len(lset) {
        layer := &lset[i]

        os.write_string(file, fmt.tprintf("# Layer %d\n", i))
        os.write_string(file, fmt.tprintf("# Bounds: (%.3f,%.3f,%.3f) to (%.3f,%.3f,%.3f)\n",
                        layer.bmin.x, layer.bmin.y, layer.bmin.z,
                        layer.bmax.x, layer.bmax.y, layer.bmax.z))
        os.write_string(file, fmt.tprintf("# Cell size: %.3f, Cell height: %.3f\n", layer.cs, layer.ch))
        os.write_string(file, fmt.tprintf("# Dimensions: %dx%d\n", layer.width, layer.height))
        os.write_string(file, fmt.tprintf("# Usable bounds: (%d,%d) to (%d,%d)\n",
                        layer.minx, layer.miny, layer.maxx, layer.maxy))
        os.write_string(file, fmt.tprintf("# Height range: %d to %d\n", layer.hmin, layer.hmax))
        os.write_string(file, "\n")

        // Sample some height data (avoid huge files)
        sample_stride := max(1, int(layer.width) / 20)  // Sample every Nth cell

        os.write_string(file, "height_samples:\n")
        for z := 0; z < int(layer.height); z += sample_stride {
            for x := 0; x < int(layer.width); x += sample_stride {
                idx := x + z * int(layer.width)
                if idx >= 0 && idx < len(layer.heights) {
                    height := layer.heights[idx]
                    area := layer.areas != nil && idx < len(layer.areas) ? layer.areas[idx] : 0

                    if height != 0xff { // Only show valid heights
                        world_x := f32(layer.minx + i32(x)) * layer.cs + layer.bmin[0]
                        world_z := f32(layer.miny + i32(z)) * layer.cs + layer.bmin[2]
                        world_y := f32(layer.hmin + i32(height)) * layer.ch + layer.bmin[1]

                        os.write_string(file, fmt.tprintf("  %.3f %.3f %.3f area=%d\n",
                                        world_x, world_y, world_z, area))
                    }
                }
            }
        }

        os.write_string(file, "\n")
    }

    log.infof("Successfully exported heightfield layer set to: %s", filepath)
    return true
}

// Export statistics and summary info about navigation data structures
dump_statistics :: proc(chf: ^Compact_Heightfield, cset: ^Contour_Set,
                          pmesh: ^Poly_Mesh, dmesh: ^Poly_Mesh_Detail,
                          filepath: string) -> bool {

    log.infof("Exporting navigation statistics to file: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create statistics file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Navigation Build Statistics\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, "\n")

    // Compact heightfield stats
    if chf != nil {
        os.write_string(file, "compact_heightfield:\n")
        os.write_string(file, fmt.tprintf("  dimensions: %dx%d\n", chf.width, chf.height))
        os.write_string(file, fmt.tprintf("  span_count: %d\n", chf.span_count))
        os.write_string(file, fmt.tprintf("  max_distance: %d\n", chf.max_distance))
        os.write_string(file, fmt.tprintf("  max_regions: %d\n", chf.max_regions))
        os.write_string(file, fmt.tprintf("  walkable_height: %d\n", chf.walkable_height))
        os.write_string(file, fmt.tprintf("  walkable_climb: %d\n", chf.walkable_climb))
        os.write_string(file, fmt.tprintf("  border_size: %d\n", chf.border_size))

        // Count cells with spans
        active_cells := 0
        for i in 0..<int(chf.width * chf.height) {
            if chf.cells[i].count > 0 {
                active_cells += 1
            }
        }
        os.write_string(file, fmt.tprintf("  active_cells: %d / %d (%.1f%%)\n",
                        active_cells, chf.width * chf.height,
                        f32(active_cells) / f32(chf.width * chf.height) * 100))
        os.write_string(file, "\n")
    }

    // Contour set stats
    if cset != nil {
        os.write_string(file, "contour_set:\n")
        os.write_string(file, fmt.tprintf("  contour_count: %d\n", len(cset.conts)))

        total_verts := 0
        total_raw_verts := 0
        for i in 0..<len(cset.conts) {
            total_verts += len(cset.conts[i].verts)
            total_raw_verts += len(cset.conts[i].rverts)
        }

        os.write_string(file, fmt.tprintf("  total_simplified_vertices: %d\n", total_verts))
        os.write_string(file, fmt.tprintf("  total_raw_vertices: %d\n", total_raw_verts))
        if total_raw_verts > 0 {
            reduction := f32(total_raw_verts - total_verts) / f32(total_raw_verts) * 100
            os.write_string(file, fmt.tprintf("  simplification_reduction: %.1f%%\n", reduction))
        }
        os.write_string(file, "\n")
    }

    // Polygon mesh stats
    if pmesh != nil {
        os.write_string(file, "polygon_mesh:\n")
        os.write_string(file, fmt.tprintf("  vertex_count: %d\n", len(pmesh.verts)))
        os.write_string(file, fmt.tprintf("  polygon_count: %d\n", pmesh.npolys))
        os.write_string(file, fmt.tprintf("  max_verts_per_poly: %d\n", pmesh.nvp))

        // Analyze polygon vertex distribution
        if pmesh.npolys > 0 {
            vertex_counts := make(map[int]int)
            defer delete(vertex_counts)

            for i in 0..<pmesh.npolys {
                pi := int(i) * int(pmesh.nvp) * 2
                nverts := 0
                for j in 0..<pmesh.nvp {
                    if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                        nverts += 1
                    } else {
                        break
                    }
                }
                vertex_counts[nverts] = vertex_counts[nverts] + 1
            }

            os.write_string(file, "  polygon_vertex_distribution:\n")
            for verts := 3; verts <= int(pmesh.nvp); verts += 1 {
                count := vertex_counts[verts]
                if count > 0 {
                    pct := f32(count) / f32(pmesh.npolys) * 100
                    os.write_string(file, fmt.tprintf("    %d_vertices: %d (%.1f%%)\n",
                                    verts, count, pct))
                }
            }
        }
        os.write_string(file, "\n")
    }

    // Detail mesh stats
    if dmesh != nil {
        os.write_string(file, "detail_mesh:\n")
        os.write_string(file, fmt.tprintf("  vertex_count: %d\n", len(dmesh.verts)))
        os.write_string(file, fmt.tprintf("  triangle_count: %d\n", len(dmesh.tris)))
        os.write_string(file, fmt.tprintf("  submesh_count: %d\n", len(dmesh.meshes)))

        if pmesh != nil && pmesh.npolys > 0 {
            detail_factor := f32(len(dmesh.tris)) / f32(pmesh.npolys)
            os.write_string(file, fmt.tprintf("  detail_triangulation_factor: %.2f\n", detail_factor))
        }
        os.write_string(file, "\n")
    }

    // Memory usage estimates
    os.write_string(file, "estimated_memory_usage:\n")
    total_bytes := 0

    if chf != nil {
        chf_bytes := int(chf.span_count) * (size_of(Compact_Span) + 2) + // spans + areas + dist
                    int(chf.width * chf.height) * size_of(Compact_Cell)
        os.write_string(file, fmt.tprintf("  compact_heightfield: %d bytes\n", chf_bytes))
        total_bytes += chf_bytes
    }

    if pmesh != nil {
        pmesh_bytes := len(pmesh.verts) * 3 * size_of(u16) +                     // vertices
                     int(pmesh.npolys) * int(pmesh.nvp) * 2 * size_of(u16) +      // polygons
                     int(pmesh.npolys) * (size_of(u16) + size_of(u16) + size_of(u8)) // regs + flags + areas
        os.write_string(file, fmt.tprintf("  polygon_mesh: %d bytes\n", pmesh_bytes))
        total_bytes += pmesh_bytes
    }

    if dmesh != nil {
        dmesh_bytes := len(dmesh.verts) * 3 * size_of(f32) +      // vertices
                      len(dmesh.tris) * 4 * size_of(u8) +         // triangles
                      len(dmesh.meshes) * 4 * size_of(u32)        // mesh info
        os.write_string(file, fmt.tprintf("  detail_mesh: %d bytes\n", dmesh_bytes))
        total_bytes += dmesh_bytes
    }

    os.write_string(file, fmt.tprintf("  total_estimated: %d bytes (%.2f KB)\n",
                    total_bytes, f32(total_bytes) / 1024.0))

    log.infof("Successfully exported navigation statistics to: %s", filepath)
    return true
}

// ========================================
// VISUALIZATION FUNCTIONS
// ========================================

// Generate visual debug mesh for heightfield
generate_heightfield_debug_mesh :: proc(hf: ^Heightfield) -> Heightfield_Debug_Mesh {
    mesh := Heightfield_Debug_Mesh{}

    if hf == nil {
        log.error("Heightfield is nil in generate_heightfield_debug_mesh")
        return mesh
    }

    log.infof("Generating heightfield debug mesh: %dx%d grid, bounds: [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f]",
              hf.width, hf.height, hf.bmin.x, hf.bmin.y, hf.bmin.z, hf.bmax.x, hf.bmax.y, hf.bmax.z)

    // Reserve space for vertices and indices
    reserve(&mesh.vertices, hf.width * hf.height * 10) // Estimate
    reserve(&mesh.indices, hf.width * hf.height * 20)   // Estimate

    // For each cell in the heightfield
    span_count := 0
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            // Get cell world position
            world_x := hf.bmin.x + f32(x) * hf.cs
            world_z := hf.bmin.z + f32(z) * hf.cs

            // Traverse all spans in this column
            span := hf.spans[x + z * hf.width]
            for span != nil {
                span_count += 1
                // Calculate span bounds
                y_min := hf.bmin.y + f32(span.smin) * hf.ch
                y_max := hf.bmin.y + f32(span.smax) * hf.ch

                // Determine color based on area
                color: [4]f32
                if span.area == u32(RC_NULL_AREA) {
                    color = DEBUG_COLOR_OBSTACLE  // NULL areas are obstacles in Recast
                } else if span.area == u32(RC_WALKABLE_AREA) {
                    color = DEBUG_COLOR_WALKABLE
                } else {
                    color = DEBUG_COLOR_NULL // Other area types
                }

                // Debug first few spans
                if span_count < 5 {
                    log.infof("Span %d: pos=[%d,%d], y=[%d-%d], area=%d",
                              span_count, x, z, span.smin, span.smax, span.area)
                }

                // Add box for this span
                add_debug_box(&mesh,
                    {world_x, y_min, world_z},
                    {world_x + hf.cs, y_max, world_z + hf.cs},
                    color)

                span = span.next
            }
        }
    }

    log.infof("Generated heightfield debug mesh: %d spans processed, %d vertices, %d indices",
              span_count, len(mesh.vertices), len(mesh.indices))

    return mesh
}

// Generate visual debug mesh for compact heightfield
generate_compact_heightfield_debug_mesh :: proc(chf: ^Compact_Heightfield) -> Heightfield_Debug_Mesh {
    mesh := Heightfield_Debug_Mesh{}

    if chf == nil do return mesh

    log.infof("Generating compact heightfield debug mesh: %dx%d grid, %d spans",
              chf.width, chf.height, chf.span_count)

    // Reserve space
    reserve(&mesh.vertices, int(chf.span_count) * 8)
    reserve(&mesh.indices, int(chf.span_count) * 36)

    // For each cell
    for z in 0..<chf.height {
        for x in 0..<chf.width {
            cell := &chf.cells[x + z * chf.width]

            // Skip empty cells
            if cell.count == 0 do continue

            // Get cell world position
            world_x := chf.bmin.x + f32(x) * chf.cs
            world_z := chf.bmin.z + f32(z) * chf.cs

            // Process each span in this cell
            for i in 0..<cell.count {
                span_idx := int(cell.index) + int(i)
                span := &chf.spans[span_idx]
                area := chf.areas[span_idx]

                // Calculate span bounds
                y_min := chf.bmin.y + f32(span.y) * chf.ch
                y_max := y_min + f32(span.h) * chf.ch

                // Determine color based on area
                color: [4]f32
                if area == RC_NULL_AREA {
                    color = DEBUG_COLOR_OBSTACLE  // NULL areas are obstacles in Recast
                } else if area == RC_WALKABLE_AREA {
                    color = DEBUG_COLOR_WALKABLE
                } else {
                    color = {1.0, 0.5, 0.0, 0.5}  // Orange for other area types
                }

                // Add box for this span
                add_debug_box(&mesh,
                    {world_x, y_min, world_z},
                    {world_x + chf.cs, y_max, world_z + chf.cs},
                    color)

                // Add edge indicators for connections
                for dir in 0..<4 {
                    if get_con(span, dir) != RC_NOT_CONNECTED {
                        add_connection_indicator(&mesh,
                            {world_x + chf.cs * 0.5, y_max, world_z + chf.cs * 0.5},
                            dir, chf.cs * 0.3)
                    }
                }
            }
        }
    }

    log.infof("Generated compact heightfield debug mesh: %d vertices, %d indices",
              len(mesh.vertices), len(mesh.indices))

    return mesh
}

// Helper to add a box to the debug mesh
add_debug_box :: proc(mesh: ^Heightfield_Debug_Mesh, min, max: [3]f32, color: [4]f32) {
    base_idx := u32(len(mesh.vertices))

    // Add 8 vertices for the box
    vertices := [][3]f32{
        {min.x, min.y, min.z}, // 0
        {max.x, min.y, min.z}, // 1
        {max.x, min.y, max.z}, // 2
        {min.x, min.y, max.z}, // 3
        {min.x, max.y, min.z}, // 4
        {max.x, max.y, min.z}, // 5
        {max.x, max.y, max.z}, // 6
        {min.x, max.y, max.z}, // 7
    }

    for v in vertices {
        append(&mesh.vertices, Heightfield_Debug_Vertex{
            position = v,
            color = color,
        })
    }

    // Add indices for 12 triangles (2 per face)
    indices := []u32{
        // Bottom face
        0, 2, 1,  0, 3, 2,
        // Top face
        4, 5, 6,  4, 6, 7,
        // Front face
        0, 1, 5,  0, 5, 4,
        // Back face
        2, 3, 7,  2, 7, 6,
        // Left face
        0, 4, 7,  0, 7, 3,
        // Right face
        1, 2, 6,  1, 6, 5,
    }

    for idx in indices {
        append(&mesh.indices, base_idx + idx)
    }
}

// Helper to add connection indicator
add_connection_indicator :: proc(mesh: ^Heightfield_Debug_Mesh, center: [3]f32, dir: int, size: f32) {
    // Get direction offset
    dx, dz: f32
    switch dir {
    case 0: dx = -1; dz = 0  // -X
    case 1: dx = 0; dz = -1  // -Z
    case 2: dx = 1; dz = 0   // +X
    case 3: dx = 0; dz = 1   // +Z
    }

    // Create a small pyramid pointing in the connection direction
    base_idx := u32(len(mesh.vertices))

    tip := center + {dx * size, 0, dz * size}
    base1 := center + {-dz * size * 0.3, -size * 0.2, dx * size * 0.3}
    base2 := center + {dz * size * 0.3, -size * 0.2, -dx * size * 0.3}
    base3 := center + {0, -size * 0.2, 0}

    // Add vertices
    append(&mesh.vertices, Heightfield_Debug_Vertex{position = tip, color = DEBUG_COLOR_EDGE})
    append(&mesh.vertices, Heightfield_Debug_Vertex{position = base1, color = DEBUG_COLOR_EDGE})
    append(&mesh.vertices, Heightfield_Debug_Vertex{position = base2, color = DEBUG_COLOR_EDGE})
    append(&mesh.vertices, Heightfield_Debug_Vertex{position = base3, color = DEBUG_COLOR_EDGE})

    // Add triangular faces
    append(&mesh.indices, base_idx + 0, base_idx + 1, base_idx + 2)
    append(&mesh.indices, base_idx + 0, base_idx + 2, base_idx + 3)
    append(&mesh.indices, base_idx + 0, base_idx + 3, base_idx + 1)
    append(&mesh.indices, base_idx + 1, base_idx + 3, base_idx + 2)
}

// Free debug mesh resources
free_heightfield_debug_mesh :: proc(mesh: ^Heightfield_Debug_Mesh) {
    delete(mesh.vertices)
    delete(mesh.indices)
}

// Export heightfield debug mesh to OBJ format for inspection
export_heightfield_debug_mesh_to_obj :: proc(mesh: ^Heightfield_Debug_Mesh, filepath: string) -> bool {
    if mesh == nil || len(mesh.vertices) == 0 || len(mesh.indices) == 0 do return false

    log.infof("Exporting heightfield debug mesh to OBJ: %s", filepath)

    file, open_err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    if open_err != os.ERROR_NONE {
        log.errorf("Failed to create OBJ file: %s", filepath)
        return false
    }
    defer os.close(file)

    // Write header
    os.write_string(file, "# Recast Heightfield Debug Visualization\n")
    os.write_string(file, fmt.tprintf("# Generated with Mjolnir Recast\n"))
    os.write_string(file, fmt.tprintf("# Vertices: %d, Triangles: %d\n",
                    len(mesh.vertices), len(mesh.indices)/3))
    os.write_string(file, "\n")

    // Write vertices with color comments
    for v in mesh.vertices {
        color_name := "unknown"
        if v.color == DEBUG_COLOR_WALKABLE {
            color_name = "walkable"
        } else if v.color == DEBUG_COLOR_OBSTACLE {
            color_name = "obstacle"  // RC_NULL_AREA spans
        } else if v.color == DEBUG_COLOR_NULL {
            color_name = "empty"
        } else if v.color == DEBUG_COLOR_EDGE {
            color_name = "edge"
        } else if v.color.r == 1.0 && v.color.g == 0.5 && v.color.b == 0.0 {
            color_name = "custom_area"
        }

        os.write_string(file, fmt.tprintf("v %.6f %.6f %.6f # %s\n",
                        v.position.x, v.position.y, v.position.z, color_name))
    }

    // Write vertex colors
    os.write_string(file, "\n# Vertex colors\n")
    for v in mesh.vertices {
        os.write_string(file, fmt.tprintf("vn %.3f %.3f %.3f\n",
                        v.color.r, v.color.g, v.color.b))
    }

    os.write_string(file, "\n")

    // Write faces
    for i := 0; i < len(mesh.indices); i += 3 {
        // OBJ uses 1-based indexing
        v1 := int(mesh.indices[i]) + 1
        v2 := int(mesh.indices[i+1]) + 1
        v3 := int(mesh.indices[i+2]) + 1

        os.write_string(file, fmt.tprintf("f %d//%d %d//%d %d//%d\n",
                        v1, v1, v2, v2, v3, v3))
    }

    log.infof("Successfully exported heightfield debug mesh to: %s", filepath)
    return true
}
