package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import vk "vendor:vulkan"
import "geometry"

DebugGrid :: struct {
    vertex_buffer: DataBuffer,
    vertex_count: u32,
    extent: i32,
}
debug_grid: DebugGrid

init_debug_grid :: proc(engine: ^Engine, extent: i32 = 100) -> vk.Result {
    ctx := &engine.vk_ctx
    // Use regular Vertex struct since that's what our pipeline expects
    vertex_count := (extent*2+1) * 4  // 2 lines per coordinate (X and Z), 2 vertices per line
    verts := make([dynamic]geometry.Vertex, 0, vertex_count)
    minor_color := [4]f32{0.5, 0.5, 0.5, 1.0}
    major_color := [4]f32{0.2, 0.2, 0.2, 1.0}
    origin_color := [4]f32{1.0, 0.0, 0.0, 1.0}

    y :f32 = 9.0
    // X lines (parallel to Z)
    for i in 0..=extent*2+1 {
        x := i - extent
        color := origin_color if x == 0 else (major_color if x % 10 == 0 else minor_color)
        // Each line needs 2 vertices
        append(&verts, geometry.Vertex{
            position = {f32(x), y, -f32(extent)},
            normal = {0, 1, 0},  // Up vector
            color = color,
            uv = {0, 0},
        })
        append(&verts, geometry.Vertex{
            position = {f32(x), y, f32(extent)},
            normal = {0, 1, 0},  // Up vector
            color = color,
            uv = {1, 0},
        })
    }

    // Z lines (parallel to X)
    for i in 0..=extent*2+1 {
        z := i - extent
        color := origin_color if z == 0 else (major_color if z % 10 == 0 else minor_color)
        append(&verts, geometry.Vertex{
            position = {-f32(extent), y, f32(z)},
            normal = {0, 1, 0},  // Up vector
            color = color,
            uv = {0, 0},
        })
        append(&verts, geometry.Vertex{
            position = {f32(extent), y, f32(z)},
            normal = {0, 1, 0},  // Up vector
            color = color,
            uv = {1, 0},
        })
    }

    // Create a temporary vertex buffer
    size := vk.DeviceSize(len(verts) * size_of(geometry.Vertex))
    debug_grid.vertex_buffer = create_host_visible_buffer(ctx, size, {.VERTEX_BUFFER}) or_return
    data_buffer_write(&debug_grid.vertex_buffer, raw_data(verts), size)

    debug_grid.vertex_count = u32(len(verts))
    debug_grid.extent = extent

    return .SUCCESS
}
// Simple grid drawing for debugging
// Draws a grid on the XZ plane centered at the origin
// minor grid: 1x1, major grid: 10x10

draw_debug_grid :: proc(engine: ^Engine, extent: i32 = 100) -> vk.Result {
    if debug_grid.extent != extent {
        init_debug_grid(engine, extent) or_return
    }
    ctx := &engine.vk_ctx
    cmd := renderer_get_command_buffer(&engine.renderer)
    vk.CmdBindPipeline(cmd, .GRAPHICS, pipelines[0])
    // Bind descriptor sets for scene uniforms (needed for view/projection)
    camera_descriptor_set := renderer_get_camera_descriptor_set(&engine.renderer)
    vk.CmdBindDescriptorSets(
        cmd,
        .GRAPHICS,
        pipeline_layouts[0],
        0,
        1,
        &camera_descriptor_set,
        0,
        nil,
    )

    // Draw the grid
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(cmd, 0, 1, &debug_grid.vertex_buffer.buffer, &offset)
    vk.CmdDraw(cmd, debug_grid.vertex_count, 1, 0, 0)
    return .SUCCESS
    // No cleanup for grid_buf (debug only)
}
