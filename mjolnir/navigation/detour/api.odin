package navigation_detour

import "core:math/linalg"
import nav_recast "../recast"

// Create navigation mesh from Recast polygon mesh
dt_create_navmesh :: proc(pmesh: ^nav_recast.Rc_Poly_Mesh, dmesh: ^nav_recast.Rc_Poly_Mesh_Detail, walkable_height: f32, walkable_radius: f32, walkable_climb: f32) -> (nav_mesh: ^Dt_Nav_Mesh, ok: bool) {
    // Create navigation mesh data
    params := Dt_Create_Nav_Mesh_Data_Params{
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
    
    nav_data, data_status := dt_create_nav_mesh_data(&params)
    if nav_recast.status_failed(data_status) {
        return nil, false
    }
    defer delete(nav_data)
    
    // Create navigation mesh
    nav_mesh = new(Dt_Nav_Mesh)
    
    mesh_params := Dt_Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = pmesh.bmax[0] - pmesh.bmin[0],
        tile_height = pmesh.bmax[2] - pmesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }
    
    init_status := dt_nav_mesh_init(nav_mesh, &mesh_params)
    if nav_recast.status_failed(init_status) {
        free(nav_mesh)
        return nil, false
    }
    
    // Add tile
    _, add_status := dt_nav_mesh_add_tile(nav_mesh, nav_data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(add_status) {
        dt_nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
        return nil, false
    }
    
    return nav_mesh, true
}

// Find path between two points
dt_find_path_points :: proc(query: ^Dt_Nav_Mesh_Query, start_pos: [3]f32, end_pos: [3]f32, filter: ^Dt_Query_Filter, path: [][3]f32) -> (path_count: int, status: nav_recast.Status) {
    half_extents := [3]f32{2.0, 1.0, 2.0}
    
    // Find start polygon
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    start_status := dt_find_nearest_poly(query, start_pos, half_extents, filter, &start_ref, &start_nearest)
    if nav_recast.status_failed(start_status) || start_ref == nav_recast.INVALID_POLY_REF {
        return 0, start_status
    }
    
    // Find end polygon
    end_ref := nav_recast.Poly_Ref(0)
    end_nearest := [3]f32{}
    end_status := dt_find_nearest_poly(query, end_pos, half_extents, filter, &end_ref, &end_nearest)
    if nav_recast.status_failed(end_status) || end_ref == nav_recast.INVALID_POLY_REF {
        return 0, end_status
    }
    
    // Find polygon path
    poly_path := make([]nav_recast.Poly_Ref, len(path))
    defer delete(poly_path)
    
    poly_path_count := i32(0)
    path_status := dt_find_path(query, start_ref, end_ref, start_nearest, end_nearest, filter, poly_path, &poly_path_count, i32(len(path)))
    if nav_recast.status_failed(path_status) || poly_path_count == 0 {
        return 0, path_status
    }
    
    // Convert to straight path
    straight_path := make([]Dt_Straight_Path_Point, len(path))
    defer delete(straight_path)
    
    straight_path_flags := make([]u8, len(path))
    defer delete(straight_path_flags)
    
    straight_path_refs := make([]nav_recast.Poly_Ref, len(path))
    defer delete(straight_path_refs)
    
    straight_path_count := i32(0)
    
    straight_status := dt_find_straight_path(query, start_nearest, end_nearest, poly_path[:poly_path_count], poly_path_count,
                                           straight_path, straight_path_flags, straight_path_refs,
                                           &straight_path_count, i32(len(path)), 0)
    if nav_recast.status_failed(straight_status) {
        return 0, straight_status
    }
    
    // Extract positions
    for i in 0..<int(straight_path_count) {
        path[i] = straight_path[i].pos
    }
    
    return int(straight_path_count), {.Success}
}