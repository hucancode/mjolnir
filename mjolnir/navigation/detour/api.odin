package navigation_detour

import "core:log"
import "core:math"
import "core:math/linalg"
import recast "../recast"

// Create navigation mesh from Recast polygon mesh
create_navmesh :: proc(pmesh: ^recast.Poly_Mesh, dmesh: ^recast.Poly_Mesh_Detail, walkable_height: f32, walkable_radius: f32, walkable_climb: f32) -> (nav_mesh: ^Nav_Mesh, ok: bool) {
    // Create navigation mesh data
    params := Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        off_mesh_con_count = 0,
        user_id = 1,
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        walkable_height = walkable_height,
        walkable_radius = walkable_radius,
        walkable_climb = walkable_climb,
    }

    nav_data, data_status := create_nav_mesh_data(&params)
    if recast.status_failed(data_status) {
        return nil, false
    }
    // Don't delete nav_data here - DT_TILE_FREE_DATA flag means Detour will manage it

    // Create navigation mesh
    nav_mesh = new(Nav_Mesh)

    mesh_params := Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = (pmesh.bmax - pmesh.bmin).x,
        tile_height = (pmesh.bmax - pmesh.bmin).z,
        max_tiles = 1,
        max_polys = 1024,
    }

    init_status := nav_mesh_init(nav_mesh, &mesh_params)
    if recast.status_failed(init_status) {
        free(nav_mesh)
        return nil, false
    }

    // Add tile
    _, add_status := nav_mesh_add_tile(nav_mesh, nav_data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
        return nil, false
    }

    return nav_mesh, true
}

// Find path between two points
find_path_points :: proc(query: ^Nav_Mesh_Query, start_pos: [3]f32, end_pos: [3]f32, filter: ^Query_Filter, path: [][3]f32) -> (path_count: int, status: recast.Status) {
    log.infof("=== find_path_points called: start=%v, end=%v, path_buffer_len=%d", start_pos, end_pos, len(path))
    half_extents := [3]f32{5.0, 5.0, 5.0}  // Use larger search radius to ensure we find polygons

    // Find start polygon
    start_status, start_ref, start_nearest := find_nearest_poly(query, start_pos, half_extents, filter)
    log.infof("find_path_points: find_nearest_poly for start returned status=%v, ref=0x%x, nearest=%v", start_status, start_ref, start_nearest)
    if recast.status_failed(start_status) || start_ref == recast.INVALID_POLY_REF {
        log.errorf("find_path_points: Failed to find start polygon, returning early")
        return 0, start_status
    }

    // Find end polygon
    end_status, end_ref, end_nearest := find_nearest_poly(query, end_pos, half_extents, filter)
    log.infof("find_path_points: find_nearest_poly for end returned status=%v, ref=0x%x, nearest=%v", end_status, end_ref, end_nearest)
    if recast.status_failed(end_status) || end_ref == recast.INVALID_POLY_REF {
        log.errorf("find_path_points: Failed to find end polygon, returning early")
        return 0, end_status
    }

    // Find polygon path
    poly_path := make([]recast.Poly_Ref, len(path))
    defer delete(poly_path)

    path_status, poly_path_count := find_path(query, start_ref, end_ref, start_nearest, end_nearest, filter, poly_path, i32(len(path)))
    log.infof("find_path_points: find_path returned status=%v, poly_path_count=%d", path_status, poly_path_count)
    if recast.status_failed(path_status) || poly_path_count == 0 {
        log.errorf("find_path_points: Failed to find polygon path or path empty, returning early")
        return 0, path_status
    }

    // Convert to straight path
    straight_path := make([]Straight_Path_Point, len(path))
    defer delete(straight_path)

    straight_path_flags := make([]u8, len(path))
    defer delete(straight_path_flags)

    straight_path_refs := make([]recast.Poly_Ref, len(path))
    defer delete(straight_path_refs)

    // Special case: if path has only 1 polygon, just return start and end points
    log.infof("find_path_points: poly_path_count = %d", poly_path_count)
    if poly_path_count == 1 {
        log.info("find_path_points: Single polygon path - returning direct line")
        path[0] = start_nearest
        if linalg.length2(end_nearest - start_nearest) > 0.0001 {  // Not the same point
            path[1] = end_nearest
            log.infof("Returning 2 points: start=%v, end=%v", start_nearest, end_nearest)
            return 2, {.Success}
        }
        log.info("Start and end are same point, returning 1")
        return 1, {.Success}
    }

    log.infof("find_path_points: About to call find_straight_path with %d polygons", poly_path_count)
    log.infof("  poly_path_count=%d, len(poly_path)=%d", poly_path_count, len(poly_path))
    log.infof("  len(straight_path)=%d, max=%d", len(straight_path), len(path))
    log.infof("  start_nearest=%v, end_nearest=%v", start_nearest, end_nearest)

    // Log the polygon path
    for i in 0..<poly_path_count {
        log.infof("  poly_path[%d] = 0x%x", i, poly_path[i])
    }

    straight_status, straight_path_count := find_straight_path(query, start_nearest, end_nearest, poly_path[:poly_path_count], poly_path_count,
                                                                straight_path, straight_path_flags, straight_path_refs,
                                                                i32(len(path)), u32(Straight_Path_Options.All_Crossings))
    log.infof("find_path_points: find_straight_path returned status=%v, count=%d", straight_status, straight_path_count)
    if recast.status_failed(straight_status) {
        log.errorf("find_path_points: find_straight_path failed with status %v", straight_status)
        return 0, straight_status
    }

    // Extract positions and filter duplicates
    path_count = 0
    last_pos := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}

    for i in 0..<int(straight_path_count) {
        pos := straight_path[i].pos
        // Skip duplicate consecutive points
        if linalg.length2(pos - last_pos) > 0.0001 { // 0.01 unit threshold squared
            path[path_count] = pos
            path_count += 1
            last_pos = pos
        }
    }

    return path_count, {.Success}
}
