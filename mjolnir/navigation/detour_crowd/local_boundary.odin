package navigation_detour_crowd

import "core:math"
import "core:slice"
import nav_recast "../recast"
import detour "../detour"

// Initialize local boundary
dt_local_boundary_init :: proc(boundary: ^Dt_Local_Boundary, max_segs: i32) -> nav_recast.Status {
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
dt_local_boundary_destroy :: proc(boundary: ^Dt_Local_Boundary) {
    if boundary == nil do return
    
    delete(boundary.segments)
    delete(boundary.polys)
    boundary.segments = nil
    boundary.polys = nil
    boundary.max_segs = 0
}

// Reset boundary data
dt_local_boundary_reset :: proc(boundary: ^Dt_Local_Boundary) {
    if boundary == nil do return
    
    clear(&boundary.segments)
    clear(&boundary.polys)
}

// Update boundary around given position
dt_local_boundary_update :: proc(boundary: ^Dt_Local_Boundary, ref: nav_recast.Poly_Ref, pos: [3]f32,
                                collision_query_range: f32, nav_query: ^detour.Dt_Nav_Mesh_Query,
                                filter: ^detour.Dt_Query_Filter) -> nav_recast.Status {
    
    if boundary == nil || nav_query == nil || filter == nil {
        return {.Invalid_Param}
    }
    
    if ref == nav_recast.INVALID_POLY_REF {
        dt_local_boundary_reset(boundary)
        return {.Success}
    }
    
    boundary.center = pos
    
    // Clear existing boundary
    dt_local_boundary_reset(boundary)
    
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
        tile, poly, get_status := detour.dt_get_tile_and_poly_by_ref(nav_query.nav_mesh, poly_ref)
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
dt_local_boundary_is_valid :: proc(boundary: ^Dt_Local_Boundary, pos: [3]f32, radius: f32) -> bool {
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
dt_local_boundary_get_closest_point :: proc(boundary: ^Dt_Local_Boundary, pos: [3]f32) -> ([3]f32, bool) {
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
        dist := nav_recast.sqr(point[0] - pos[0]) + nav_recast.sqr(point[2] - pos[2])
        
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
    px, pz := point[0], point[2]
    ax, az := seg_start[0], seg_start[2] 
    bx, bz := seg_end[0], seg_end[2]
    
    dx := bx - ax
    dz := bz - az
    
    if dx*dx + dz*dz > 1e-6 {
        t := ((px - ax) * dx + (pz - az) * dz) / (dx*dx + dz*dz)
        
        if t > 1.0 {
            dx = px - bx
            dz = pz - bz
        } else if t > 0.0 {
            dx = px - (ax + t*dx)
            dz = pz - (az + t*dz)
        } else {
            dx = px - ax
            dz = pz - az
        }
    } else {
        dx = px - ax
        dz = pz - az
    }
    
    return math.sqrt(dx*dx + dz*dz)
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
        
        result := [3]f32{
            ax + t * dx,
            seg_start[1] + t * (seg_end[1] - seg_start[1]), // Interpolate Y as well
            az + t * dz,
        }
        return result
    }
    
    return seg_start
}

// Get number of boundary segments
dt_local_boundary_get_segment_count :: proc(boundary: ^Dt_Local_Boundary) -> i32 {
    if boundary == nil do return 0
    return i32(len(boundary.segments))
}

// Get specific boundary segment
dt_local_boundary_get_segment :: proc(boundary: ^Dt_Local_Boundary, index: i32) -> ([6]f32, bool) {
    if boundary == nil || index < 0 || index >= i32(len(boundary.segments)) {
        return {}, false
    }
    return boundary.segments[index], true
}

// Get boundary polygon for specific segment
dt_local_boundary_get_segment_poly :: proc(boundary: ^Dt_Local_Boundary, index: i32) -> (nav_recast.Poly_Ref, bool) {
    if boundary == nil || index < 0 || index >= i32(len(boundary.polys)) {
        return nav_recast.INVALID_POLY_REF, false
    }
    return boundary.polys[index], true
}

// Check if position is inside boundary area
dt_local_boundary_contains_point :: proc(boundary: ^Dt_Local_Boundary, pos: [3]f32, radius: f32) -> bool {
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
dt_local_boundary_project_point :: proc(boundary: ^Dt_Local_Boundary, pos: [3]f32, radius: f32) -> [3]f32 {
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
            dx := result[0] - closest[0]
            dz := result[2] - closest[2]
            d := math.sqrt(dx*dx + dz*dz)
            
            if d > 1e-6 {
                // Normalize and scale to required distance
                scale := radius / d
                result[0] = closest[0] + dx * scale
                result[2] = closest[2] + dz * scale
            } else {
                // Point is exactly on boundary - move it slightly away
                // Use segment normal
                seg_dx := seg_end[0] - seg_start[0]
                seg_dz := seg_end[2] - seg_start[2]
                
                // Perpendicular vector (rotate 90 degrees)
                norm_x := -seg_dz
                norm_z := seg_dx
                norm_len := math.sqrt(norm_x*norm_x + norm_z*norm_z)
                
                if norm_len > 1e-6 {
                    norm_x /= norm_len
                    norm_z /= norm_len
                    
                    result[0] = closest[0] + norm_x * radius
                    result[2] = closest[2] + norm_z * radius
                }
            }
        }
    }
    
    return result
}