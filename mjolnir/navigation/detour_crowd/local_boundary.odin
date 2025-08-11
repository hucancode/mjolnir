package navigation_detour_crowd

import "core:math"
import "core:math/linalg"
import "core:slice"
import nav_recast "../recast"
import detour "../detour"

// Initialize local boundary
local_boundary_init :: proc(boundary: ^Local_Boundary, max_segs: i32) -> nav_recast.Status {
    if boundary == nil || max_segs <= 0 {
        return {.Invalid_Param}
    }
    
    boundary.segments = make([dynamic][6]f32, 0, max_segs)
    boundary.polys = make([dynamic]nav_recast.Poly_Ref, 0, max_segs)
    boundary.max_segs = max_segs
    boundary.center = {}
    
    return {.Success}
}

// Destroy local boundary
local_boundary_destroy :: proc(boundary: ^Local_Boundary) {
    if boundary == nil do return
    
    delete(boundary.segments)
    delete(boundary.polys)
    boundary.segments = nil
    boundary.polys = nil
    boundary.max_segs = 0
}

// Reset boundary data
local_boundary_reset :: proc(boundary: ^Local_Boundary) {
    if boundary == nil do return
    
    clear(&boundary.segments)
    clear(&boundary.polys)
}

// Update boundary around given position
local_boundary_update :: proc(boundary: ^Local_Boundary, ref: nav_recast.Poly_Ref, pos: [3]f32,
                                collision_query_range: f32, nav_query: ^detour.Nav_Mesh_Query,
                                filter: ^detour.Query_Filter) -> nav_recast.Status {
    
    if boundary == nil || nav_query == nil || filter == nil {
        return {.Invalid_Param}
    }
    
    if ref == nav_recast.INVALID_POLY_REF {
        local_boundary_reset(boundary)
        return {.Success}
    }
    
    boundary.center = pos
    
    // Clear existing boundary
    local_boundary_reset(boundary)
    
    // Find polygons around the agent
    MAX_LOCAL_POLYS :: 256
    polys := make([]nav_recast.Poly_Ref, MAX_LOCAL_POLYS)
    defer delete(polys)
    
    poly_count, status := detour.dt_find_polys_around_circle(
        nav_query, ref, pos, collision_query_range, filter, polys
    )
    
    if nav_recast.status_failed(status) {
        return status
    }
    
    // Extract boundary segments from the polygons
    for i in 0..<poly_count {
        if len(boundary.segments) >= boundary.max_segs do break
        
        poly_ref := polys[i]
        
        // Get polygon and tile
        tile, poly, get_status := detour.get_tile_and_poly_by_ref(nav_query.nav_mesh, poly_ref)
        if nav_recast.status_failed(get_status) || tile == nil || poly == nil do continue
        
        // Check each edge of the polygon
        for j in 0..<poly.vert_count {
            if len(boundary.segments) >= boundary.max_segs do break
            
            // Check if this edge is a boundary (no neighbor)
            neighbor := poly.neis[j]
            if neighbor != 0 do continue  // Has neighbor, not a boundary
            
            // Get edge vertices
            va_idx := poly.verts[j]
            vb_idx := poly.verts[(j + 1) % poly.vert_count]
            
            if int(va_idx) >= len(tile.verts) || int(vb_idx) >= len(tile.verts) do continue
            
            va := tile.verts[va_idx]
            vb := tile.verts[vb_idx]
            
            // Check if edge is within collision range
            dist_to_seg := dt_distance_point_to_segment_2d(pos, va, vb)
            if dist_to_seg > collision_query_range do continue
            
            // Add boundary segment
            segment := [6]f32{va[0], va[1], va[2], vb[0], vb[1], vb[2]}
            append(&boundary.segments, segment)
            append(&boundary.polys, poly_ref)
        }
    }
    
    return {.Success}
}

// Check if point is valid (not too close to boundary)
local_boundary_is_valid :: proc(boundary: ^Local_Boundary, pos: [3]f32, radius: f32) -> bool {
    if boundary == nil do return true
    
    // Check distance to all boundary segments
    for segment in boundary.segments {
        seg_start := [3]f32{segment[0], segment[1], segment[2]}
        seg_end := [3]f32{segment[3], segment[4], segment[5]}
        
        dist := dt_distance_point_to_segment_2d(pos, seg_start, seg_end)
        if dist < radius {
            return false
        }
    }
    
    return true
}

// Get closest point on boundary
local_boundary_get_closest_point :: proc(boundary: ^Local_Boundary, pos: [3]f32) -> ([3]f32, bool) {
    if boundary == nil || len(boundary.segments) == 0 {
        return pos, false
    }
    
    closest_point := pos
    min_dist := math.F32_MAX
    found := false
    
    for segment in boundary.segments {
        seg_start := [3]f32{segment[0], segment[1], segment[2]}
        seg_end := [3]f32{segment[3], segment[4], segment[5]}
        
        point := dt_closest_point_on_segment_2d(pos, seg_start, seg_end)
        dist := linalg.length2((point - pos).xz)
        
        if dist < min_dist {
            min_dist = dist
            closest_point = point
            found = true
        }
    }
    
    return closest_point, found
}

// Distance from point to line segment in 2D (XZ plane)
dt_distance_point_to_segment_2d :: proc(point, seg_start, seg_end: [3]f32) -> f32 {
    // Use XZ plane for 2D calculations
    p := point.xz
    a := seg_start.xz
    b := seg_end.xz
    
    seg := b - a
    seg_len_sq := linalg.length2(seg)
    
    diff: [2]f32
    if seg_len_sq > 1e-6 {
        t := linalg.dot(p - a, seg) / seg_len_sq
        
        if t > 1.0 {
            diff = p - b
        } else if t > 0.0 {
            diff = p - (a + t*seg)
        } else {
            diff = p - a
        }
    } else {
        diff = p - a
    }
    
    return linalg.length(diff)
}

// Find closest point on line segment in 2D (XZ plane)
dt_closest_point_on_segment_2d :: proc(point, seg_start, seg_end: [3]f32) -> [3]f32 {
    // Use XZ plane for 2D calculations
    px, pz := point[0], point[2]
    ax, az := seg_start[0], seg_start[2]
    bx, bz := seg_end[0], seg_end[2]
    
    dx := bx - ax
    dz := bz - az
    
    if dx*dx + dz*dz > 1e-6 {
        t := ((px - ax) * dx + (pz - az) * dz) / (dx*dx + dz*dz)
        t = nav_recast.clamp(t, 0.0, 1.0)
        
        return linalg.mix(seg_start, seg_end, t)
    }
    
    return seg_start
}

// Get number of boundary segments
local_boundary_get_segment_count :: proc(boundary: ^Local_Boundary) -> i32 {
    if boundary == nil do return 0
    return i32(len(boundary.segments))
}

// Get specific boundary segment
local_boundary_get_segment :: proc(boundary: ^Local_Boundary, index: i32) -> ([6]f32, bool) {
    if boundary == nil || index < 0 || index >= i32(len(boundary.segments)) {
        return {}, false
    }
    return boundary.segments[index], true
}

// Get boundary polygon for specific segment
local_boundary_get_segment_poly :: proc(boundary: ^Local_Boundary, index: i32) -> (nav_recast.Poly_Ref, bool) {
    if boundary == nil || index < 0 || index >= i32(len(boundary.polys)) {
        return nav_recast.INVALID_POLY_REF, false
    }
    return boundary.polys[index], true
}

// Check if position is inside boundary area
local_boundary_contains_point :: proc(boundary: ^Local_Boundary, pos: [3]f32, radius: f32) -> bool {
    if boundary == nil do return true
    
    // Simple check: ensure we're not too close to any boundary segment
    for segment in boundary.segments {
        seg_start := [3]f32{segment[0], segment[1], segment[2]}
        seg_end := [3]f32{segment[3], segment[4], segment[5]}
        
        dist := dt_distance_point_to_segment_2d(pos, seg_start, seg_end)
        if dist < radius {
            return false
        }
    }
    
    return true
}

// Project point away from boundary if too close
local_boundary_project_point :: proc(boundary: ^Local_Boundary, pos: [3]f32, radius: f32) -> [3]f32 {
    if boundary == nil || len(boundary.segments) == 0 {
        return pos
    }
    
    result := pos
    
    // Check each boundary segment
    for segment in boundary.segments {
        seg_start := [3]f32{segment[0], segment[1], segment[2]}
        seg_end := [3]f32{segment[3], segment[4], segment[5]}
        
        dist := dt_distance_point_to_segment_2d(result, seg_start, seg_end)
        
        if dist < radius {
            // Find closest point on segment and push away
            closest := dt_closest_point_on_segment_2d(result, seg_start, seg_end)
            
            // Calculate direction away from boundary
            dir := result.xz - closest.xz
            d := linalg.length(dir)
            
            if d > 1e-6 {
                // Normalize and scale to required distance
                dir_scaled := linalg.normalize(dir) * radius
                result[0] = closest[0] + dir_scaled.x
                result[2] = closest[2] + dir_scaled.y
            } else {
                // Point is exactly on boundary - move it slightly away
                // Use segment normal
                seg_dir := seg_end.xz - seg_start.xz
                
                // Perpendicular vector (rotate 90 degrees)
                norm := [2]f32{-seg_dir.y, seg_dir.x}
                norm_len := linalg.length(norm)
                
                if norm_len > 1e-6 {
                    norm_scaled := linalg.normalize(norm) * radius
                    
                    result[0] = closest[0] + norm_scaled.x
                    result[2] = closest[2] + norm_scaled.y
                }
            }
        }
    }
    
    return result
}