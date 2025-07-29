package navigation_detour

import "core:math/linalg"
import nav_recast "../recast"

// High-level API for Detour pathfinding
// This file provides simplified interfaces for common use cases

// Simple navigation context for high-level API
Nav_Context :: struct {
    nav_mesh: ^Dt_Nav_Mesh,
    query:    Dt_Nav_Mesh_Query,
    filter:   Dt_Query_Filter,
}

// Initialize navigation context from Recast data
nav_init_from_recast :: proc(ctx: ^Nav_Context, pmesh: ^nav_recast.Rc_Poly_Mesh, dmesh: ^nav_recast.Rc_Poly_Mesh_Detail) -> nav_recast.Status {
    // Create navigation mesh parameters
    params := Dt_Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        off_mesh_con_count = 0,
        user_id = 1,
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        walkable_height = 2.0,
        walkable_radius = 0.6,
        walkable_climb = 0.9,
    }
    
    // Create navigation mesh data
    nav_data, data_status := dt_create_nav_mesh_data(&params)
    if nav_recast.status_failed(data_status) {
        return data_status
    }
    defer delete(nav_data)
    
    // Create navigation mesh
    ctx.nav_mesh = new(Dt_Nav_Mesh)
    
    mesh_params := Dt_Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = pmesh.bmax[0] - pmesh.bmin[0],
        tile_height = pmesh.bmax[2] - pmesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }
    
    init_status := dt_nav_mesh_init(ctx.nav_mesh, &mesh_params)
    if nav_recast.status_failed(init_status) {
        free(ctx.nav_mesh)
        return init_status
    }
    
    // Add tile
    _, add_status := dt_nav_mesh_add_tile(ctx.nav_mesh, nav_data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(add_status) {
        dt_nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        return add_status
    }
    
    // Initialize query
    query_status := dt_nav_mesh_query_init(&ctx.query, ctx.nav_mesh, 512)
    if nav_recast.status_failed(query_status) {
        dt_nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        return query_status
    }
    
    // Initialize default filter
    dt_query_filter_init(&ctx.filter)
    
    return {.Success}
}

// Clean up navigation context
nav_destroy :: proc(ctx: ^Nav_Context) {
    if ctx.nav_mesh != nil {
        dt_nav_mesh_query_destroy(&ctx.query)
        dt_nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
    }
}

// Find a path between two world positions
nav_find_path :: proc(ctx: ^Nav_Context, start_pos: [3]f32, end_pos: [3]f32, max_path_points: int) -> ([][3]f32, nav_recast.Status) {
    if ctx.nav_mesh == nil {
        return nil, {.Invalid_Param}
    }
    
    half_extents := [3]f32{2.0, 1.0, 2.0}
    
    // Find start polygon
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    start_status := dt_find_nearest_poly(&ctx.query, start_pos, half_extents, &ctx.filter, &start_ref, &start_nearest)
    if nav_recast.status_failed(start_status) || start_ref == nav_recast.INVALID_POLY_REF {
        return nil, {.Invalid_Param}
    }
    
    // Find end polygon
    end_ref := nav_recast.Poly_Ref(0)
    end_nearest := [3]f32{}
    end_status := dt_find_nearest_poly(&ctx.query, end_pos, half_extents, &ctx.filter, &end_ref, &end_nearest)
    if nav_recast.status_failed(end_status) || end_ref == nav_recast.INVALID_POLY_REF {
        return nil, {.Invalid_Param}
    }
    
    // Find polygon path
    poly_path := make([]nav_recast.Poly_Ref, max_path_points)
    defer delete(poly_path)
    
    poly_path_count := i32(0)
    path_status := dt_find_path(&ctx.query, start_ref, end_ref, start_nearest, end_nearest, 
                               &ctx.filter, poly_path, &poly_path_count, i32(max_path_points))
    if nav_recast.status_failed(path_status) || poly_path_count == 0 {
        return nil, path_status
    }
    
    // Convert to straight path
    straight_path := make([]Dt_Straight_Path_Point, max_path_points)
    defer delete(straight_path)
    
    straight_path_flags := make([]u8, max_path_points)
    defer delete(straight_path_flags)
    
    straight_path_refs := make([]nav_recast.Poly_Ref, max_path_points)
    defer delete(straight_path_refs)
    
    straight_path_count := i32(0)
    
    straight_status := dt_find_straight_path(&ctx.query, start_nearest, end_nearest, 
                                           poly_path[:poly_path_count], poly_path_count,
                                           straight_path, straight_path_flags, straight_path_refs,
                                           &straight_path_count, i32(max_path_points), 0)
    if nav_recast.status_failed(straight_status) {
        return nil, straight_status
    }
    
    // Extract positions
    result := make([][3]f32, straight_path_count)
    for i in 0..<int(straight_path_count) {
        result[i] = straight_path[i].pos
    }
    
    return result, {.Success}
}

// Check if a position is on the navigation mesh
nav_is_position_valid :: proc(ctx: ^Nav_Context, pos: [3]f32) -> bool {
    if ctx.nav_mesh == nil {
        return false
    }
    
    half_extents := [3]f32{0.1, 0.1, 0.1}
    nearest_ref := nav_recast.Poly_Ref(0)
    nearest_pt := [3]f32{}
    
    status := dt_find_nearest_poly(&ctx.query, pos, half_extents, &ctx.filter, &nearest_ref, &nearest_pt)
    return nav_recast.status_succeeded(status) && nearest_ref != nav_recast.INVALID_POLY_REF
}

// Project a position onto the navigation mesh
nav_project_position :: proc(ctx: ^Nav_Context, pos: [3]f32) -> ([3]f32, bool) {
    if ctx.nav_mesh == nil {
        return pos, false
    }
    
    half_extents := [3]f32{2.0, 1.0, 2.0}
    nearest_ref := nav_recast.Poly_Ref(0)
    nearest_pt := [3]f32{}
    
    status := dt_find_nearest_poly(&ctx.query, pos, half_extents, &ctx.filter, &nearest_ref, &nearest_pt)
    if nav_recast.status_succeeded(status) && nearest_ref != nav_recast.INVALID_POLY_REF {
        return nearest_pt, true
    }
    
    return pos, false
}

// Cast a ray along the navigation mesh
nav_raycast :: proc(ctx: ^Nav_Context, start_pos: [3]f32, end_pos: [3]f32) -> (hit_pos: [3]f32, hit: bool, status: nav_recast.Status) {
    if ctx.nav_mesh == nil {
        return start_pos, false, {.Invalid_Param}
    }
    
    half_extents := [3]f32{1.0, 1.0, 1.0}
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    
    find_status := dt_find_nearest_poly(&ctx.query, start_pos, half_extents, &ctx.filter, &start_ref, &start_nearest)
    if nav_recast.status_failed(find_status) || start_ref == nav_recast.INVALID_POLY_REF {
        return start_pos, false, find_status
    }
    
    hit_result := Dt_Raycast_Hit{}
    path := make([]nav_recast.Poly_Ref, 32)
    defer delete(path)
    
    path_count := i32(0)
    
    raycast_status := dt_raycast(&ctx.query, start_ref, start_nearest, end_pos, &ctx.filter, 0,
                                &hit_result, path, &path_count, 32)
    
    if nav_recast.status_failed(raycast_status) {
        return start_pos, false, raycast_status
    }
    
    // Calculate hit position
    ray_dir := end_pos - start_nearest
    ray_len := linalg.length(ray_dir)
    
    if hit_result.t < ray_len {
        hit_pos = start_nearest + linalg.normalize(ray_dir) * hit_result.t
        return hit_pos, true, {.Success}
    }
    
    return end_pos, false, {.Success}
}

// Find a random walkable position
nav_find_random_position :: proc(ctx: ^Nav_Context) -> ([3]f32, bool) {
    if ctx.nav_mesh == nil {
        return {0, 0, 0}, false
    }
    
    random_ref := nav_recast.Poly_Ref(0)
    random_pt := [3]f32{}
    
    status := dt_find_random_point(&ctx.query, &ctx.filter, &random_ref, &random_pt)
    if nav_recast.status_succeeded(status) && random_ref != nav_recast.INVALID_POLY_REF {
        return random_pt, true
    }
    
    return {0, 0, 0}, false
}

// Find a random position within a radius of a given point
nav_find_random_position_around :: proc(ctx: ^Nav_Context, center: [3]f32, radius: f32) -> ([3]f32, bool) {
    if ctx.nav_mesh == nil {
        return center, false
    }
    
    half_extents := [3]f32{radius, radius, radius}
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    
    find_status := dt_find_nearest_poly(&ctx.query, center, half_extents, &ctx.filter, &start_ref, &start_nearest)
    if nav_recast.status_failed(find_status) || start_ref == nav_recast.INVALID_POLY_REF {
        return center, false
    }
    
    random_ref := nav_recast.Poly_Ref(0)
    random_pt := [3]f32{}
    
    status := dt_find_random_point_around_circle(&ctx.query, start_ref, start_nearest, radius, &ctx.filter, &random_ref, &random_pt)
    if nav_recast.status_succeeded(status) && random_ref != nav_recast.INVALID_POLY_REF {
        return random_pt, true
    }
    
    return center, false
}

// Move a position along the navigation mesh surface
nav_move_along_surface :: proc(ctx: ^Nav_Context, start_pos: [3]f32, end_pos: [3]f32) -> ([3]f32, nav_recast.Status) {
    if ctx.nav_mesh == nil {
        return start_pos, {.Invalid_Param}
    }
    
    half_extents := [3]f32{1.0, 1.0, 1.0}
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    
    find_status := dt_find_nearest_poly(&ctx.query, start_pos, half_extents, &ctx.filter, &start_ref, &start_nearest)
    if nav_recast.status_failed(find_status) || start_ref == nav_recast.INVALID_POLY_REF {
        return start_pos, find_status
    }
    
    result_pos := [3]f32{}
    visited := make([]nav_recast.Poly_Ref, 16)
    defer delete(visited)
    
    visited_count := i32(0)
    
    status := dt_move_along_surface(&ctx.query, start_ref, start_nearest, end_pos, &ctx.filter,
                                   &result_pos, visited, &visited_count, 16)
    
    return result_pos, status
}

// Get distance to wall from a position
nav_distance_to_wall :: proc(ctx: ^Nav_Context, pos: [3]f32, radius: f32) -> (f32, nav_recast.Status) {
    if ctx.nav_mesh == nil {
        return 0, {.Invalid_Param}
    }
    
    half_extents := [3]f32{radius, radius, radius}
    center_ref := nav_recast.Poly_Ref(0)
    center_nearest := [3]f32{}
    
    find_status := dt_find_nearest_poly(&ctx.query, pos, half_extents, &ctx.filter, &center_ref, &center_nearest)
    if nav_recast.status_failed(find_status) || center_ref == nav_recast.INVALID_POLY_REF {
        return 0, find_status
    }
    
    // Simple implementation: raycast in multiple directions to find nearest wall
    min_distance := radius
    directions := [][3]f32{
        {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
        {0.707, 0, 0.707}, {-0.707, 0, 0.707}, {0.707, 0, -0.707}, {-0.707, 0, -0.707},
    }
    
    for dir in directions {
        end_pos := center_nearest + dir * radius
        hit_pos, hit, _ := nav_raycast(ctx, center_nearest, end_pos)
        
        if hit {
            distance := linalg.distance(center_nearest, hit_pos)
            min_distance = min(min_distance, distance)
        }
    }
    
    return min_distance, {.Success}
}

// Set area traversal cost for pathfinding
nav_set_area_cost :: proc(ctx: ^Nav_Context, area_id: int, cost: f32) {
    if area_id >= 0 && area_id < nav_recast.DT_MAX_AREAS {
        ctx.filter.area_cost[area_id] = cost
    }
}

// Set polygon flags for filtering
nav_set_include_flags :: proc(ctx: ^Nav_Context, flags: u16) {
    ctx.filter.include_flags = flags
}

nav_set_exclude_flags :: proc(ctx: ^Nav_Context, flags: u16) {
    ctx.filter.exclude_flags = flags
}