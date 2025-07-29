package navigation_recast

import "core:log"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

// Debug mesh export utilities for Recast navigation data

// Export polygon mesh to OBJ format
rc_dump_poly_mesh_to_obj :: proc(pmesh: ^Rc_Poly_Mesh, filepath: string) -> bool {
    if pmesh == nil || pmesh.nverts == 0 || pmesh.npolys == 0 do return false

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
    os.write_string(file, fmt.tprintf("# Vertices: %d, Polygons: %d\n", pmesh.nverts, pmesh.npolys))
    os.write_string(file, "\n")

    // Write vertices
    for i in 0..<pmesh.nverts {
        vi := i * 3
        x := f32(pmesh.verts[vi+0]) * pmesh.cs + pmesh.bmin[0]
        y := f32(pmesh.verts[vi+1]) * pmesh.ch + pmesh.bmin[1]
        z := f32(pmesh.verts[vi+2]) * pmesh.cs + pmesh.bmin[2]

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
rc_dump_detail_mesh_to_obj :: proc(dmesh: ^Rc_Poly_Mesh_Detail, filepath: string) -> bool {
    if dmesh == nil || dmesh.nverts == 0 || dmesh.ntris == 0 do return false

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
                    dmesh.nverts, dmesh.ntris, dmesh.nmeshes))
    os.write_string(file, "\n")

    // Write vertices
    for i in 0..<dmesh.nverts {
        vi := i * 3
        x := dmesh.verts[vi+0]
        y := dmesh.verts[vi+1]
        z := dmesh.verts[vi+2]

        os.write_string(file, fmt.tprintf("v %.6f %.6f %.6f\n", x, y, z))
    }

    os.write_string(file, "\n")

    // Write triangular faces
    for i in 0..<dmesh.ntris {
        ti := i * 4
        v1 := int(dmesh.tris[ti+0]) + 1  // OBJ uses 1-based indexing
        v2 := int(dmesh.tris[ti+1]) + 1
        v3 := int(dmesh.tris[ti+2]) + 1
        // dmesh.tris[ti+3] is area ID

        os.write_string(file, fmt.tprintf("f %d %d %d\n", v1, v2, v3))
    }

    log.infof("Successfully exported detail mesh to: %s", filepath)
    return true
}

// Export contour set to a simple text format for debugging
rc_dump_contour_set :: proc(cset: ^Rc_Contour_Set, filepath: string) -> bool {
    if cset == nil || cset.nconts == 0 do return false

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
    os.write_string(file, fmt.tprintf("# Contours: %d\n", cset.nconts))
    os.write_string(file, fmt.tprintf("# Bounds: (%.3f,%.3f,%.3f) to (%.3f,%.3f,%.3f)\n",
                    cset.bmin.x, cset.bmin.y, cset.bmin.z,
                    cset.bmax.x, cset.bmax.y, cset.bmax.z))
    os.write_string(file, fmt.tprintf("# Cell size: %.3f, Cell height: %.3f\n", cset.cs, cset.ch))
    os.write_string(file, "\n")

    for i in 0..<cset.nconts {
        cont := &cset.conts[i]

        os.write_string(file, fmt.tprintf("# Contour %d\n", i))
        os.write_string(file, fmt.tprintf("# Vertices: %d, Raw vertices: %d\n", cont.nverts, cont.nrverts))
        os.write_string(file, fmt.tprintf("# Region: %d, Area: %d\n", cont.reg, cont.area))
        os.write_string(file, "\n")

        // Write simplified contour vertices
        os.write_string(file, "simplified_vertices:\n")
        for j in 0..<cont.nverts {
            vi := j * 4
            x := f32(cont.verts[vi+0]) * cset.cs + cset.bmin[0]
            y := f32(cont.verts[vi+1]) * cset.ch + cset.bmin[1]
            z := f32(cont.verts[vi+2]) * cset.cs + cset.bmin[2]
            flags := cont.verts[vi+3]

            os.write_string(file, fmt.tprintf("  %.6f %.6f %.6f %d\n", x, y, z, flags))
        }

        // Write raw contour vertices
        os.write_string(file, "raw_vertices:\n")
        for j in 0..<cont.nrverts {
            vi := j * 4
            x := f32(cont.rverts[vi+0]) * cset.cs + cset.bmin[0]
            y := f32(cont.rverts[vi+1]) * cset.ch + cset.bmin[1]
            z := f32(cont.rverts[vi+2]) * cset.cs + cset.bmin[2]
            flags := cont.rverts[vi+3]

            os.write_string(file, fmt.tprintf("  %.6f %.6f %.6f %d\n", x, y, z, flags))
        }

        os.write_string(file, "\n")
    }

    log.infof("Successfully exported contour set to: %s", filepath)
    return true
}

// Export compact heightfield to a text format for debugging
rc_dump_compact_heightfield :: proc(chf: ^Rc_Compact_Heightfield, filepath: string) -> bool {
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
            conn := rc_get_con(s, dir)
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
rc_dump_heightfield_layers :: proc(lset: [dynamic]Rc_Heightfield_Layer, filepath: string) -> bool {
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
rc_dump_statistics :: proc(chf: ^Rc_Compact_Heightfield, cset: ^Rc_Contour_Set,
                          pmesh: ^Rc_Poly_Mesh, dmesh: ^Rc_Poly_Mesh_Detail,
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
        os.write_string(file, fmt.tprintf("  contour_count: %d\n", cset.nconts))

        total_verts := 0
        total_raw_verts := 0
        for i in 0..<cset.nconts {
            total_verts += int(cset.conts[i].nverts)
            total_raw_verts += int(cset.conts[i].nrverts)
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
        os.write_string(file, fmt.tprintf("  vertex_count: %d\n", pmesh.nverts))
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
        os.write_string(file, fmt.tprintf("  vertex_count: %d\n", dmesh.nverts))
        os.write_string(file, fmt.tprintf("  triangle_count: %d\n", dmesh.ntris))
        os.write_string(file, fmt.tprintf("  submesh_count: %d\n", dmesh.nmeshes))

        if pmesh != nil && pmesh.npolys > 0 {
            detail_factor := f32(dmesh.ntris) / f32(pmesh.npolys)
            os.write_string(file, fmt.tprintf("  detail_triangulation_factor: %.2f\n", detail_factor))
        }
        os.write_string(file, "\n")
    }

    // Memory usage estimates
    os.write_string(file, "estimated_memory_usage:\n")
    total_bytes := 0

    if chf != nil {
        chf_bytes := int(chf.span_count) * (size_of(Rc_Compact_Span) + 2) + // spans + areas + dist
                    int(chf.width * chf.height) * size_of(Rc_Compact_Cell)
        os.write_string(file, fmt.tprintf("  compact_heightfield: %d bytes\n", chf_bytes))
        total_bytes += chf_bytes
    }

    if pmesh != nil {
        pmesh_bytes := int(pmesh.nverts) * 3 * size_of(u16) +                     // vertices
                     int(pmesh.npolys) * int(pmesh.nvp) * 2 * size_of(u16) +      // polygons
                     int(pmesh.npolys) * (size_of(u16) + size_of(u16) + size_of(u8)) // regs + flags + areas
        os.write_string(file, fmt.tprintf("  polygon_mesh: %d bytes\n", pmesh_bytes))
        total_bytes += pmesh_bytes
    }

    if dmesh != nil {
        dmesh_bytes := int(dmesh.nverts) * 3 * size_of(f32) +      // vertices
                      int(dmesh.ntris) * 4 * size_of(u8) +         // triangles
                      int(dmesh.nmeshes) * 4 * size_of(u32)        // mesh info
        os.write_string(file, fmt.tprintf("  detail_mesh: %d bytes\n", dmesh_bytes))
        total_bytes += dmesh_bytes
    }

    os.write_string(file, fmt.tprintf("  total_estimated: %d bytes (%.2f KB)\n",
                    total_bytes, f32(total_bytes) / 1024.0))

    log.infof("Successfully exported navigation statistics to: %s", filepath)
    return true
}
