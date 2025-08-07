package navigation

import "core:log"
import "core:slice"
import "../geometry"

// Load OBJ file and extract raw data for navigation mesh input
load_obj_to_navmesh_input :: proc(filename: string, scale: f32 = 1.0, default_area: u8 = 1) -> (vertices: []f32, indices: []i32, areas: []u8, ok: bool) {
    geom, load_ok := geometry.load_obj(filename, scale)
    if !load_ok {
        return nil, nil, nil, false
    }
    defer geometry.delete_geometry(geom)

    // Extract vertex positions
    vertex_count := len(geom.vertices)
    vertices = make([]f32, vertex_count * 3)
    for i in 0..<vertex_count {
        vertices[i*3 + 0] = geom.vertices[i].position.x
        vertices[i*3 + 1] = geom.vertices[i].position.y
        vertices[i*3 + 2] = geom.vertices[i].position.z
    }

    // Convert indices from u32 to i32
    index_count := len(geom.indices)
    indices = make([]i32, index_count)
    for i in 0..<index_count {
        indices[i] = i32(geom.indices[i])
    }

    // Create area array
    triangle_count := index_count / 3
    areas = make([]u8, triangle_count)
    slice.fill(areas, default_area)

    return vertices, indices, areas, true
}
