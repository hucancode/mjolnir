package test_detour

import "../../mjolnir/navigation/detour"
import "../../mjolnir/navigation/recast"
import "core:testing"
import "core:fmt"
import "core:os"
import "core:time"
import "core:log"

@(test)
test_navmesh_file_serialization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    vertices := [][3]f32{
        {-5, 0, -5}, {5, 0, -5}, {5, 0, 5}, {-5, 0, 5},
    }
    indices := []i32{0, 1, 2, 0, 2, 3}
    areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}
    pmesh, dmesh, build_ok := build_test_mesh(vertices, indices, areas)
    testing.expect(t, build_ok, "Failed to build test mesh")
    defer {
        recast.free_poly_mesh(pmesh)
        recast.free_poly_mesh_detail(dmesh)
    }
    nav_mesh, create_ok := detour.create_navmesh(pmesh, dmesh, 2.0, 0.6, 0.9)
    testing.expect(t, create_ok, "Failed to create navigation mesh")
    defer {
        detour.nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
    }
    navmesh_file := "test_navmesh.navmesh"
    defer os.remove(navmesh_file)
    save_ok := detour.save_navmesh_to_file(nav_mesh, navmesh_file)
    testing.expect(t, save_ok, "Failed to save navigation mesh to file")
    loaded_nav_mesh, load_ok := detour.load_navmesh_from_file(navmesh_file)
    testing.expect(t, load_ok, "Failed to load navigation mesh from file")
    testing.expect(t, loaded_nav_mesh != nil, "Loaded navigation mesh should not be nil")
    defer {
        detour.nav_mesh_destroy(loaded_nav_mesh)
        free(loaded_nav_mesh)
    }
    testing.expect(t, nav_mesh.params.max_tiles == loaded_nav_mesh.params.max_tiles,
                  "Max tiles should match")
    testing.expect(t, nav_mesh.params.max_polys == loaded_nav_mesh.params.max_polys,
                  "Max polys should match")
    original_tile_count := count_valid_tiles(nav_mesh)
    loaded_tile_count := count_valid_tiles(loaded_nav_mesh)
    testing.expect(t, original_tile_count == loaded_tile_count,
                  "Tile counts should match")
    testing.expect(t, loaded_tile_count > 0, "Should have at least one tile")
}

@(test)
test_navmesh_data_serialization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    vertices := [][3]f32{
        {-10, 0, -10}, {10, 0, -10}, {10, 0, 10}, {-10, 0, 10},
    }
    indices := []i32{0, 1, 2, 0, 2, 3}
    areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}
    pmesh, dmesh, build_ok := build_test_mesh(vertices, indices, areas)
    testing.expect(t, build_ok, "Failed to build test mesh")
    defer {
        recast.free_poly_mesh(pmesh)
        recast.free_poly_mesh_detail(dmesh)
    }
    params := detour.Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        walkable_height = 2.0,
        walkable_radius = 0.6,
        walkable_climb = 0.9,
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        user_id = 12345,
        off_mesh_con_count = 0,
    }
    nav_data, create_status := detour.create_nav_mesh_data(&params)
    testing.expect(t, recast.status_succeeded(create_status), "Failed to create nav mesh data")
    testing.expect(t, len(nav_data) > 0, "Navigation data should not be empty")
    defer delete(nav_data)
    data_file := "test_navdata.bin"
    defer os.remove(data_file)
    save_ok := detour.save_navmesh_data_to_file(nav_data, data_file)
    testing.expect(t, save_ok, "Failed to save navigation data to file")
    loaded_data, load_ok := detour.load_navmesh_data_from_file(data_file)
    testing.expect(t, load_ok, "Failed to load navigation data from file")
    testing.expect(t, len(loaded_data) == len(nav_data), "Data sizes should match")
    defer delete(loaded_data)
    data_match := true
    for i in 0..<len(nav_data) {
        if nav_data[i] != loaded_data[i] {
            data_match = false
            break
        }
    }
    testing.expect(t, data_match, "Loaded data should match original data")
}

@(test)
test_bake_and_save_workflow :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    vertices := [][3]f32{
        {-8, 0, -8}, {8, 0, -8}, {8, 0, 8}, {-8, 0, 8},
        // Add a raised platform
        {-2, 1, -2}, {2, 1, -2}, {2, 1, 2}, {-2, 1, 2},
    }
    indices := []i32{
        // Floor
        0, 1, 2, 0, 2, 3,
        // Platform
        4, 5, 6, 4, 6, 7,
    }
    areas := []u8{
        recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA,
        recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA,
    }
    pmesh, dmesh, build_ok := build_test_mesh(vertices, indices, areas)
    testing.expect(t, build_ok, "Failed to build test mesh")
    defer {
        recast.free_poly_mesh(pmesh)
        recast.free_poly_mesh_detail(dmesh)
    }
    baked_file := "test_baked.navmesh"
    defer os.remove(baked_file)
    bake_ok := detour.bake_and_save_navmesh(pmesh, dmesh, 2.0, 0.6, 0.9, baked_file)
    testing.expect(t, bake_ok, "Failed to bake and save navigation mesh")
    nav_mesh, query, runtime_ok := detour.load_navmesh_for_runtime(baked_file)
    testing.expect(t, runtime_ok, "Failed to load navigation mesh for runtime")
    testing.expect(t, nav_mesh != nil && query != nil, "Navigation mesh and query should not be nil")
    defer {
        detour.nav_mesh_query_destroy(query)
        free(query)
        detour.nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
    }
    start_pos := [3]f32{-6, 0.1, -6}
    end_pos := [3]f32{6, 0.1, 6}
    path := make([][3]f32, 32)
    defer delete(path)
    filter: detour.Query_Filter
    detour.query_filter_init(&filter)
    path_count, path_status := detour.find_path_points(query, start_pos, end_pos, &filter, path)
    testing.expect(t, recast.status_succeeded(path_status), "Pathfinding should succeed")
    testing.expect(t, path_count > 0, "Should find a path")
}

build_test_mesh :: proc(vertices: [][3]f32, indices: []i32, areas: []u8) -> (^recast.Poly_Mesh, ^recast.Poly_Mesh_Detail, bool) {
    cfg: recast.Config
    cfg.bmin, cfg.bmax = recast.calc_bounds(vertices)
    cfg.cs = 0.3
    cfg.ch = 0.2
    cfg.walkable_slope_angle = 45.0
    cfg.walkable_height = 10
    cfg.walkable_climb = 4
    cfg.walkable_radius = 2
    cfg.max_edge_len = 12
    cfg.max_simplification_error = 1.3
    cfg.min_region_area = 8
    cfg.merge_region_area = 20
    cfg.max_verts_per_poly = 6
    cfg.detail_sample_dist = 6.0
    cfg.detail_sample_max_error = 1.0
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)
    hf := recast.create_heightfield(cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    if hf == nil do return nil, nil, false
    defer recast.free_heightfield(hf)
    if !recast.rasterize_triangles(vertices, indices, areas, hf, cfg.walkable_climb) do return nil, nil, false
    recast.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    recast.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    recast.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
    chf := recast.create_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf)
    if chf == nil do return nil, nil, false
    defer recast.free_compact_heightfield(chf)
    recast.erode_walkable_area(cfg.walkable_radius, chf)
    recast.build_distance_field(chf)
    recast.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
    cset := recast.create_contour_set(chf, cfg.max_simplification_error, cfg.max_edge_len)
    if cset == nil do return nil, nil, false
    defer recast.free_contour_set(cset)
    pmesh := recast.create_poly_mesh(cset, cfg.max_verts_per_poly)
    if pmesh == nil do return nil, nil, false
    dmesh := recast.create_poly_mesh_detail(pmesh, chf, cfg.detail_sample_dist, cfg.detail_sample_max_error)
    if dmesh == nil {
        recast.free_poly_mesh(pmesh)
        return nil, nil, false
    }
    return pmesh, dmesh, true
}

// Helper function to count valid tiles in a navigation mesh
count_valid_tiles :: proc(nav_mesh: ^detour.Nav_Mesh) -> int {
    count := 0
    for i in 0..<nav_mesh.max_tiles {
        tile := &nav_mesh.tiles[i]
        if tile.header != nil && len(tile.data) > 0 {
            count += 1
        }
    }
    return count
}
