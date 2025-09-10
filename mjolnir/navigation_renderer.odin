package mjolnir

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "geometry"
import "gpu"
import "resource"
import "navigation/recast"
import vk "vendor:vulkan"

RendererNavMesh :: struct {
    // Vulkan resources
    pipeline:                vk.Pipeline,
    pipeline_layout:         vk.PipelineLayout,
    debug_pipeline:          vk.Pipeline,
    debug_pipeline_layout:   vk.PipelineLayout,

    // Vertex data for navigation mesh
    vertex_buffer:           gpu.DataBuffer(NavMeshVertex),
    index_buffer:            gpu.DataBuffer(u32),
    vertex_count:            u32,
    index_count:             u32,

    // Path rendering data
    path_vertex_buffer:      gpu.DataBuffer(NavMeshVertex),
    path_vertex_count:       u32,
    path_enabled:            bool,
    path_color:              [4]f32,

    // Rendering state
    enabled:                 bool,
    debug_mode:              bool,
    height_offset:           f32,  // Offset above ground
    alpha:                   f32,  // Transparency
    color_mode:              NavMeshColorMode,
    debug_render_mode:       NavMeshDebugMode,
    base_color:              [3]f32,
}

// Vertex structure for navigation mesh rendering
NavMeshVertex :: struct {
    position: [3]f32,
    color:    [4]f32,
    normal:   [3]f32,
}

NavMeshColorMode :: enum u32 {
    Area_Colors = 0,  // Color by area type
    Uniform = 1,      // Single color
    Height_Based = 2, // Color by height
    Random_Colors = 3, // Random color per polygon
    Region_Colors = 4, // Color by connectivity region
}

NavMeshDebugMode :: enum u32 {
    Wireframe = 0,    // Show wireframe
    Normals = 1,      // Show normals as colors
    Connectivity = 2, // Show polygon connectivity
}

NavMeshPushConstants :: struct {
    world:         matrix[4,4]f32,
    camera_index:  u32,
    height_offset: f32,
    alpha:         f32,
    color_mode:    u32,
    padding:       [11]u32,
}

NavMeshDebugPushConstants :: struct {
    world:         matrix[4,4]f32,
    camera_index:  u32,
    height_offset: f32,
    line_width:    f32,
    debug_mode:    u32,
    debug_color:   [3]f32,
    padding:       [8]u32,
}

// Maximum path segments (line segments between waypoints)
MAX_PATH_SEGMENTS :: 1000

// Default area colors for different area types
AREA_COLORS := [7][4]f32{
    0 = {0.0, 0.0, 0.0, 0.0},     // NULL_AREA - transparent
    1 = {0.0, 0.8, 0.2, 0.6},     // WALKABLE_AREA - green
    2 = {0.8, 0.4, 0.0, 0.6},     // JUMP_AREA - orange
    3 = {0.2, 0.4, 0.8, 0.6},     // WATER_AREA - blue
    4 = {0.8, 0.2, 0.2, 0.6},     // DOOR_AREA - red
    5 = {0.6, 0.6, 0.6, 0.6},     // ELEVATOR_AREA - gray
    6 = {0.8, 0.8, 0.0, 0.6},     // LADDER_AREA - yellow
}

navmesh_init :: proc(renderer: ^RendererNavMesh, gpu_context: ^gpu.GPUContext, warehouse: ^ResourceWarehouse) -> vk.Result {
    // Initialize default values
    renderer.enabled = true
    renderer.debug_mode = false
    renderer.height_offset = 0.01
    renderer.alpha = 0.6
    renderer.color_mode = .Area_Colors
    renderer.debug_render_mode = .Wireframe
    renderer.base_color = {0.0, 0.8, 0.2}

    // Initialize path rendering defaults
    renderer.path_enabled = false
    renderer.path_color = {1.0, 1.0, 0.0, 1.0} // Yellow by default
    renderer.path_vertex_count = 0

    // Create pipelines
    result := create_navmesh_pipelines(renderer, gpu_context, warehouse)
    if result != .SUCCESS {
        log.errorf("Failed to create navigation mesh pipelines: %v", result)
        return result
    }

    // Initialize empty buffers with larger capacity for complex navigation meshes
    renderer.vertex_buffer = gpu.create_host_visible_buffer(gpu_context, NavMeshVertex, 16384, {.VERTEX_BUFFER}) or_return
    renderer.index_buffer = gpu.create_host_visible_buffer(gpu_context, u32, 32768, {.INDEX_BUFFER}) or_return

    // Pre-allocate path buffer for MAX_PATH_SEGMENTS line segments (2 vertices per segment)
    renderer.path_vertex_buffer = gpu.create_host_visible_buffer(gpu_context, NavMeshVertex, MAX_PATH_SEGMENTS * 2, {.VERTEX_BUFFER}) or_return

    log.info("Navigation mesh renderer initialized successfully")
    return .SUCCESS
}

navmesh_deinit :: proc(renderer: ^RendererNavMesh, gpu_context: ^gpu.GPUContext) {
    if renderer.pipeline != 0 {
        vk.DestroyPipeline(gpu_context.device, renderer.pipeline, nil)
    }
    if renderer.pipeline_layout != 0 {
        vk.DestroyPipelineLayout(gpu_context.device, renderer.pipeline_layout, nil)
    }
    if renderer.debug_pipeline != 0 {
        vk.DestroyPipeline(gpu_context.device, renderer.debug_pipeline, nil)
    }
    if renderer.debug_pipeline_layout != 0 {
        vk.DestroyPipelineLayout(gpu_context.device, renderer.debug_pipeline_layout, nil)
    }

    gpu.data_buffer_deinit(gpu_context, &renderer.vertex_buffer)
    gpu.data_buffer_deinit(gpu_context, &renderer.index_buffer)
    gpu.data_buffer_deinit(gpu_context, &renderer.path_vertex_buffer)
}

navmesh_build_from_recast :: proc(renderer: ^RendererNavMesh, gpu_context: ^gpu.GPUContext,
                                  poly_mesh: ^recast.Poly_Mesh, detail_mesh: ^recast.Poly_Mesh_Detail) -> bool {
    if poly_mesh == nil {
        log.error("Cannot build navigation mesh renderer: polygon mesh is nil")
        return false
    }

    use_detail_mesh := detail_mesh != nil && len(detail_mesh.verts) > 0

    vertices := make([dynamic]NavMeshVertex, 0, len(poly_mesh.verts))
    indices := make([dynamic]u32, 0, poly_mesh.npolys * 6)  // Estimate
    defer delete(vertices)
    defer delete(indices)

    if use_detail_mesh && len(detail_mesh.verts) > 0 {
        // Use detail mesh vertices (already in world space)
        base_vert_count := len(poly_mesh.verts)

        // First add the base poly mesh vertices
        for i in 0..<len(poly_mesh.verts) {

            v := poly_mesh.verts[i]
            pos := [3]f32{
                f32(v.x) * poly_mesh.cs + poly_mesh.bmin[0],
                f32(v.y) * poly_mesh.ch + poly_mesh.bmin[1],
                f32(v.z) * poly_mesh.cs + poly_mesh.bmin[2],
            }

            append(&vertices, NavMeshVertex{
                position = pos,
                color = [4]f32{0.0, 0.8, 0.2, renderer.alpha},
                normal = [3]f32{0, 1, 0},
            })
        }

        // Then add detail vertices
        for i in 0..<len(detail_mesh.verts) {

            pos := detail_mesh.verts[i]

            append(&vertices, NavMeshVertex{
                position = pos,
                color = [4]f32{0.0, 0.8, 0.2, renderer.alpha},
                normal = [3]f32{0, 1, 0},
            })
        }
    } else {
        // Convert polygon mesh vertices
        for i in 0..<len(poly_mesh.verts) {

            v := poly_mesh.verts[i]
            pos := [3]f32{
                f32(v.x) * poly_mesh.cs + poly_mesh.bmin.x,
                f32(v.y) * poly_mesh.ch + poly_mesh.bmin.y,
                f32(v.z) * poly_mesh.cs + poly_mesh.bmin.z,
            }

            // Default normal pointing up
            normal := [3]f32{0, 1, 0}

            // Default color (will be overridden based on color mode)
            color := [4]f32{0.0, 0.8, 0.2, renderer.alpha}

            append(&vertices, NavMeshVertex{
                position = pos,
                color = color,
                normal = normal,
            })
        }
    }

    // Convert polygon indices
    if use_detail_mesh && len(detail_mesh.meshes) > 0 {
        // Use detail mesh triangles
        for i in 0..<len(detail_mesh.meshes) {
            if int(i) >= int(poly_mesh.npolys) do break

            // Get mesh info from detail mesh

            mesh_info := detail_mesh.meshes[i]
            base_tri := mesh_info[0]
            num_tris := mesh_info[1]
            base_vert := mesh_info[2]
            num_verts := mesh_info[3]

            area_id := poly_mesh.areas[i] if len(poly_mesh.areas) > int(i) else 1
            region_id := poly_mesh.regs[i] if len(poly_mesh.regs) > int(i) else 0
            area_color := get_area_color(area_id, renderer.color_mode, renderer.base_color, renderer.alpha, u32(i), region_id)

            // Add triangles from detail mesh
            for j in 0..<int(num_tris) {
                tri_idx := int(base_tri) + j
                if tri_idx >= len(detail_mesh.tris) do continue

                tri := detail_mesh.tris[tri_idx]
                // Detail mesh triangle indices are relative to base vertex
                v0 := u32(tri[0])
                v1 := u32(tri[1])
                v2 := u32(tri[2])

                // If vertex is 0xff, it refers to polygon mesh vertex
                if v0 < 0xff {
                    v0 += base_vert + u32(len(poly_mesh.verts))
                } else {
                    v0 = u32(tri[0]) - 0xff
                }

                if v1 < 0xff {
                    v1 += base_vert + u32(len(poly_mesh.verts))
                } else {
                    v1 = u32(tri[1]) - 0xff
                }

                if v2 < 0xff {
                    v2 += base_vert + u32(len(poly_mesh.verts))
                } else {
                    v2 = u32(tri[2]) - 0xff
                }

                append(&indices, v0, v1, v2)

                // Update vertex colors
                if int(v0) < len(vertices) do vertices[v0].color = area_color
                if int(v1) < len(vertices) do vertices[v1].color = area_color
                if int(v2) < len(vertices) do vertices[v2].color = area_color
            }
        }
    } else {
        // Original polygon mesh triangulation
        for i in 0..<poly_mesh.npolys {
        poly_base := int(i) * int(poly_mesh.nvp) * 2
        area_id := poly_mesh.areas[i] if len(poly_mesh.areas) > int(i) else 1

        // Get region for connectivity coloring
        region_id := poly_mesh.regs[i] if len(poly_mesh.regs) > int(i) else 0

        // Get area color (pass polygon index for random colors and region for connectivity)
        area_color := get_area_color(area_id, renderer.color_mode, renderer.base_color, renderer.alpha, u32(i), region_id)

        // Count valid vertices in this polygon
        poly_verts: [dynamic]u32
        defer delete(poly_verts)

        for j in 0..<poly_mesh.nvp {
            vert_idx := poly_mesh.polys[poly_base + int(j)]
            if vert_idx == recast.RC_MESH_NULL_IDX do break
            append(&poly_verts, u32(vert_idx))

            // Update vertex color
            if int(vert_idx) < len(vertices) {
                vertices[vert_idx].color = area_color
            }
        }


        // Triangulate polygon (simple fan triangulation)
        if len(poly_verts) >= 3 {
            for j in 1..<len(poly_verts) - 1 {
                append(&indices, poly_verts[0])
                append(&indices, poly_verts[j])
                append(&indices, poly_verts[j + 1])
            }
        }
    }
    } // Close the else block for detail mesh

    // Update vertex and index counts
    renderer.vertex_count = u32(len(vertices))
    renderer.index_count = u32(len(indices))

    log.infof("Navigation mesh data: %d vertices, %d indices", renderer.vertex_count, renderer.index_count)

    if renderer.vertex_count == 0 || renderer.index_count == 0 {
        log.warn("Navigation mesh has no renderable geometry")
        return true
    }

    // Check buffer capacity
    if renderer.vertex_count > 16384 {
        log.errorf("Too many vertices (%d) for buffer size (16384)", renderer.vertex_count)
        return false
    }
    if renderer.index_count > 32768 {
        log.errorf("Too many indices (%d) for buffer size (32768)", renderer.index_count)
        return false
    }

    // Upload to GPU buffers
    vertex_result := gpu.data_buffer_write(&renderer.vertex_buffer, vertices[:])
    if vertex_result != .SUCCESS {
        log.error("Failed to upload navigation mesh vertex data")
        return false
    }

    index_result := gpu.data_buffer_write(&renderer.index_buffer, indices[:])
    if index_result != .SUCCESS {
        log.error("Failed to upload navigation mesh index data")
        return false
    }

    log.infof("Built navigation mesh renderer: %d vertices, %d indices (%d triangles)",
              renderer.vertex_count, renderer.index_count, renderer.index_count / 3)
    return true
}

generate_random_color :: proc(seed: u32, alpha: f32) -> [4]f32 {
    h := f32((seed * 137) % 360) / 360.0
    s: f32 = 0.8
    v: f32 = 0.8

    c := v * s
    x := c * f32(1.0 - math.abs(math.mod(f64(h) * 6.0, 2.0) - 1.0))
    m := v - c

    rgb: [3]f32
    if h < 1.0/6.0      do rgb = {c, x, 0}
    else if h < 2.0/6.0 do rgb = {x, c, 0}
    else if h < 3.0/6.0 do rgb = {0, c, x}
    else if h < 4.0/6.0 do rgb = {0, x, c}
    else if h < 5.0/6.0 do rgb = {x, 0, c}
    else                do rgb = {c, 0, x}

    return {rgb.x + m, rgb.y + m, rgb.z + m, alpha}
}

// Get color for area type
get_area_color :: proc(area_id: u8, color_mode: NavMeshColorMode, base_color: [3]f32, alpha: f32, poly_id: u32 = 0, region_id: u16 = 0) -> [4]f32 {
    switch color_mode {
    case .Area_Colors:
        if int(area_id) < len(AREA_COLORS) {
            color := AREA_COLORS[area_id]
            color.a = alpha  // Override alpha
            return color
        }
        return {0.5, 0.5, 0.5, alpha}  // Default gray

    case .Uniform:
        return {base_color.x, base_color.y, base_color.z, alpha}

    case .Height_Based:
        // Height-based coloring would require height information
        // For now, use a gradient based on area_id as a proxy
        hue := f32(area_id) / 8.0
        return {hue, 1.0 - hue, 0.5, alpha}

    case .Random_Colors:
        // Generate deterministic random color based on polygon ID
        return generate_random_color(poly_id, alpha)

    case .Region_Colors:
        // Generate distinct colors for different regions
        // Use region_id to generate a unique color for each connected region
        return generate_random_color(u32(region_id), alpha)
    }

    return {base_color.x, base_color.y, base_color.z, alpha}
}

navmesh_update_path :: proc(renderer: ^RendererNavMesh, path_points: [][3]f32, path_color: [4]f32 = {1.0, 1.0, 0.0, 1.0}) {
    if len(path_points) < 2 {
        renderer.path_enabled = false
        renderer.path_vertex_count = 0
        return
    }

    // Build triangulated line strips from path points
    // For each line segment, create a quad (2 triangles) to simulate thick lines
    vertices := make([dynamic]NavMeshVertex)
    defer delete(vertices)

    line_width: f32 = 0.15 // Width of the line in world units

    // For each pair of consecutive points, create a quad
    for i in 0..<len(path_points)-1 {
        start := path_points[i]
        end := path_points[i+1]

        // Calculate line direction and perpendicular
        dir := linalg.normalize(end - start)
        // Use cross product with up vector to get perpendicular direction
        perp := linalg.normalize(linalg.cross(dir, [3]f32{0, 1, 0})) * line_width

        // If line is vertical, use different perpendicular
        if abs(dir.y) > 0.99 {
            perp = linalg.normalize(linalg.cross(dir, [3]f32{1, 0, 0})) * line_width
        }

        // Create quad vertices (two triangles)
        // First triangle
        append(&vertices, NavMeshVertex{
            position = start - perp,
            color = path_color,
            normal = {0, 1, 0},
        })
        append(&vertices, NavMeshVertex{
            position = start + perp,
            color = path_color,
            normal = {0, 1, 0},
        })
        append(&vertices, NavMeshVertex{
            position = end - perp,
            color = path_color,
            normal = {0, 1, 0},
        })

        // Second triangle
        append(&vertices, NavMeshVertex{
            position = start + perp,
            color = path_color,
            normal = {0, 1, 0},
        })
        append(&vertices, NavMeshVertex{
            position = end + perp,
            color = path_color,
            normal = {0, 1, 0},
        })
        append(&vertices, NavMeshVertex{
            position = end - perp,
            color = path_color,
            normal = {0, 1, 0},
        })

        // Limit to maximum segments
        if len(vertices) >= MAX_PATH_SEGMENTS * 6 {
            log.warnf("Path exceeds maximum segments (%d), truncating", MAX_PATH_SEGMENTS)
            break
        }
    }

    // Update GPU buffer
    if len(vertices) > 0 {
        result := gpu.data_buffer_write(&renderer.path_vertex_buffer, vertices[:])
        if result != .SUCCESS {
            log.error("Failed to upload path vertex data")
            renderer.path_enabled = false
            renderer.path_vertex_count = 0
            return
        }
        renderer.path_vertex_count = u32(len(vertices))
        renderer.path_enabled = true
        renderer.path_color = path_color
    } else {
        renderer.path_enabled = false
        renderer.path_vertex_count = 0
    }
}

navmesh_clear_path :: proc(renderer: ^RendererNavMesh) {
    renderer.path_enabled = false
    renderer.path_vertex_count = 0
}

navmesh_render :: proc(renderer: ^RendererNavMesh, command_buffer: vk.CommandBuffer,
                      world_matrix: matrix[4,4]f32, camera_index: u32) {
    if !renderer.enabled || renderer.vertex_count == 0 || renderer.index_count == 0 do return

    pipeline := renderer.debug_pipeline if renderer.debug_mode else renderer.pipeline
    pipeline_layout := renderer.debug_pipeline_layout if renderer.debug_mode else renderer.pipeline_layout

    vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)

    // Bind vertex and index buffers
    vertex_buffers := []vk.Buffer{renderer.vertex_buffer.buffer}
    offsets := []vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(vertex_buffers), raw_data(offsets))
    vk.CmdBindIndexBuffer(command_buffer, renderer.index_buffer.buffer, 0, .UINT32)

    // Set push constants
    if renderer.debug_mode {
        push_constants := NavMeshDebugPushConstants{
            world = world_matrix,
            camera_index = camera_index,
            height_offset = renderer.height_offset,
            line_width = 1.0,
            debug_mode = u32(renderer.debug_render_mode),
            debug_color = renderer.base_color,
        }
        vk.CmdPushConstants(command_buffer, pipeline_layout, {.VERTEX, .FRAGMENT},
                           0, size_of(NavMeshDebugPushConstants), &push_constants)
    } else {
        push_constants := NavMeshPushConstants{
            world = world_matrix,
            camera_index = camera_index,
            height_offset = renderer.height_offset,
            alpha = renderer.alpha,
            color_mode = u32(renderer.color_mode),
        }
        vk.CmdPushConstants(command_buffer, pipeline_layout, {.VERTEX, .FRAGMENT},
                           0, size_of(NavMeshPushConstants), &push_constants)
    }

    // Draw navmesh
    vk.CmdDrawIndexed(command_buffer, renderer.index_count, 1, 0, 0, 0)

    // Render path if enabled
    if renderer.path_enabled && renderer.path_vertex_count >= 3 {
        // Path is rendered as triangulated quads using the main pipeline
        vk.CmdBindPipeline(command_buffer, .GRAPHICS, renderer.pipeline)

        // Bind path vertex buffer
        path_vertex_buffers := []vk.Buffer{renderer.path_vertex_buffer.buffer}
        vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(path_vertex_buffers), raw_data(offsets))

        // Set push constants for path rendering
        path_push_constants := NavMeshPushConstants{
            world = world_matrix,
            camera_index = camera_index,
            height_offset = renderer.height_offset + 0.15, // Slightly higher than navmesh
            alpha = 1.0, // Fully opaque for path
            color_mode = u32(NavMeshColorMode.Uniform), // Use uniform color from vertex data
        }
        vk.CmdPushConstants(command_buffer, renderer.pipeline_layout, {.VERTEX, .FRAGMENT},
                           0, size_of(NavMeshPushConstants), &path_push_constants)

        // Draw path triangles
        vk.CmdDraw(command_buffer, renderer.path_vertex_count, 1, 0, 0)
    }
}

create_navmesh_pipelines :: proc(renderer: ^RendererNavMesh, gpu_context: ^gpu.GPUContext, warehouse: ^ResourceWarehouse) -> vk.Result {
    // Load shaders
    navmesh_vert_code := #load("shader/navmesh/vert.spv")
    navmesh_vert := gpu.create_shader_module(gpu_context, navmesh_vert_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_vert, nil)

    navmesh_frag_code := #load("shader/navmesh/frag.spv")
    navmesh_frag := gpu.create_shader_module(gpu_context, navmesh_frag_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_frag, nil)

    navmesh_debug_vert_code := #load("shader/navmesh_debug/vert.spv")
    navmesh_debug_vert := gpu.create_shader_module(gpu_context, navmesh_debug_vert_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_debug_vert, nil)

    navmesh_debug_frag_code := #load("shader/navmesh_debug/frag.spv")
    navmesh_debug_frag := gpu.create_shader_module(gpu_context, navmesh_debug_frag_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_debug_frag, nil)

    // Create descriptor set layouts (using camera buffer from warehouse)
    set_layouts := []vk.DescriptorSetLayout{warehouse.camera_buffer_set_layout}

    // Create pipeline layouts
    push_constant_range := vk.PushConstantRange{
        stageFlags = {.VERTEX, .FRAGMENT},
        offset = 0,
        size = size_of(NavMeshPushConstants),
    }

    layout_info := vk.PipelineLayoutCreateInfo{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = u32(len(set_layouts)),
        pSetLayouts = raw_data(set_layouts),
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_constant_range,
    }

    vk.CreatePipelineLayout(gpu_context.device, &layout_info, nil, &renderer.pipeline_layout) or_return

    // Debug pipeline layout (different push constants)
    debug_push_constant_range := vk.PushConstantRange{
        stageFlags = {.VERTEX, .FRAGMENT},
        offset = 0,
        size = size_of(NavMeshDebugPushConstants),
    }

    debug_layout_info := layout_info
    debug_layout_info.pPushConstantRanges = &debug_push_constant_range

    vk.CreatePipelineLayout(gpu_context.device, &debug_layout_info, nil, &renderer.debug_pipeline_layout) or_return

    // Vertex input description
    vertex_binding := vk.VertexInputBindingDescription{
        binding = 0,
        stride = size_of(NavMeshVertex),
        inputRate = .VERTEX,
    }

    vertex_attributes := []vk.VertexInputAttributeDescription{
        {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, position))},
        {location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(NavMeshVertex, color))},
        {location = 2, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, normal))},
    }

    vertex_input := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertex_binding,
        vertexAttributeDescriptionCount = u32(len(vertex_attributes)),
        pVertexAttributeDescriptions = raw_data(vertex_attributes),
    }

    // Common pipeline state
    input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }

    viewport_state := vk.PipelineViewportStateCreateInfo{
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount = 1,
    }

    multisampling := vk.PipelineMultisampleStateCreateInfo{
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    // Depth testing enabled, writing disabled (transparent overlay)
    depth_stencil := vk.PipelineDepthStencilStateCreateInfo{
        sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable = true,
        depthWriteEnable = false,  // Don't write depth for transparent navmesh
        depthCompareOp = .LESS_OR_EQUAL,
    }

    dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo{
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_states)),
        pDynamicStates = raw_data(dynamic_states),
    }

    // Render target formats (using transparent renderer format)
    depth_format: vk.Format = .D32_SFLOAT
    color_format: vk.Format = .B8G8R8A8_SRGB

    rendering_info := vk.PipelineRenderingCreateInfo{
        sType = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount = 1,
        pColorAttachmentFormats = &color_format,
        depthAttachmentFormat = depth_format,
    }

    // Create main navigation mesh pipeline (with blending)
    rasterizer := vk.PipelineRasterizationStateCreateInfo{
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode = {},  // No culling for transparent navmesh
        frontFace = .COUNTER_CLOCKWISE,
        lineWidth = 1.0,
    }

    color_blend_attachment := vk.PipelineColorBlendAttachmentState{
        blendEnable = true,
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp = .ADD,
        colorWriteMask = {.R, .G, .B, .A},
    }

    color_blending := vk.PipelineColorBlendStateCreateInfo{
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &color_blend_attachment,
    }

    shader_stages := []vk.PipelineShaderStageCreateInfo{
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.VERTEX},
            module = navmesh_vert,
            pName = "main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.FRAGMENT},
            module = navmesh_frag,
            pName = "main",
        },
    }

    pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount = u32(len(shader_stages)),
        pStages = raw_data(shader_stages),
        pVertexInputState = &vertex_input,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState = &multisampling,
        pDepthStencilState = &depth_stencil,
        pColorBlendState = &color_blending,
        pDynamicState = &dynamic_state,
        layout = renderer.pipeline_layout,
        pNext = &rendering_info,
    }

    vk.CreateGraphicsPipelines(gpu_context.device, 0, 1, &pipeline_info, nil, &renderer.pipeline) or_return

    // Create debug pipeline (wireframe mode)
    debug_rasterizer := rasterizer
    debug_rasterizer.polygonMode = .LINE
    debug_rasterizer.lineWidth = 2.0

    // No blending for debug wireframe
    debug_color_blend_attachment := vk.PipelineColorBlendAttachmentState{
        blendEnable = false,
        colorWriteMask = {.R, .G, .B, .A},
    }

    debug_color_blending := vk.PipelineColorBlendStateCreateInfo{
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &debug_color_blend_attachment,
    }

    debug_shader_stages := []vk.PipelineShaderStageCreateInfo{
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.VERTEX},
            module = navmesh_debug_vert,
            pName = "main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.FRAGMENT},
            module = navmesh_debug_frag,
            pName = "main",
        },
    }

    // Update vertex input for debug shaders (different layout)
    debug_vertex_attributes := []vk.VertexInputAttributeDescription{
        {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, position))},
        {location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, normal))},
    }

    debug_vertex_input := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertex_binding,
        vertexAttributeDescriptionCount = u32(len(debug_vertex_attributes)),
        pVertexAttributeDescriptions = raw_data(debug_vertex_attributes),
    }

    debug_pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount = u32(len(debug_shader_stages)),
        pStages = raw_data(debug_shader_stages),
        pVertexInputState = &debug_vertex_input,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &debug_rasterizer,
        pMultisampleState = &multisampling,
        pDepthStencilState = &depth_stencil,
        pColorBlendState = &debug_color_blending,
        pDynamicState = &dynamic_state,
        layout = renderer.debug_pipeline_layout,
        pNext = &rendering_info,
    }

    vk.CreateGraphicsPipelines(gpu_context.device, 0, 1, &debug_pipeline_info, nil, &renderer.debug_pipeline) or_return

    log.info("Navigation mesh pipelines created successfully")
    return .SUCCESS
}

// ========================================
// PUBLIC API
// ========================================

navmesh_get_enabled :: proc(renderer: ^RendererNavMesh) -> bool { return renderer.enabled }
navmesh_get_debug_mode :: proc(renderer: ^RendererNavMesh) -> bool { return renderer.debug_mode }
navmesh_get_alpha :: proc(renderer: ^RendererNavMesh) -> f32 { return renderer.alpha }
navmesh_get_height_offset :: proc(renderer: ^RendererNavMesh) -> f32 { return renderer.height_offset }
navmesh_get_color_mode :: proc(renderer: ^RendererNavMesh) -> NavMeshColorMode { return renderer.color_mode }
navmesh_get_base_color :: proc(renderer: ^RendererNavMesh) -> [3]f32 { return renderer.base_color }
navmesh_get_debug_render_mode :: proc(renderer: ^RendererNavMesh) -> NavMeshDebugMode { return renderer.debug_render_mode }

navmesh_clear :: proc(renderer: ^RendererNavMesh) {
    renderer.vertex_count = 0
    renderer.index_count = 0
}

navmesh_get_triangle_count :: proc(renderer: ^RendererNavMesh) -> u32 { return renderer.index_count / 3 }
navmesh_get_vertex_count :: proc(renderer: ^RendererNavMesh) -> u32 { return renderer.vertex_count }
navmesh_has_data :: proc(renderer: ^RendererNavMesh) -> bool { return renderer.vertex_count > 0 && renderer.index_count > 0 }
