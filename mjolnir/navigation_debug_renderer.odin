package mjolnir

import "core:log"
import "core:math/linalg"
import "gpu"
import "navigation"
import "resource"
import vk "vendor:vulkan"

// Load navigation debug shaders
SHADER_NAVMESH_DEBUG_VERT :: #load("shader/navmesh_debug/vert.spv")
SHADER_NAVMESH_DEBUG_FRAG :: #load("shader/navmesh_debug/frag.spv")

// Elevation constants for visibility
NAVMESH_DEBUG_ELEVATION :: 0.1  // How much to elevate the navmesh for visibility
PATH_DEBUG_ELEVATION    :: 0.15   // How much to elevate the path line above ground

// Debug renderer state
DebugRenderer :: struct {
  is_initialized: bool,
  vertex_buffer:  gpu.DataBuffer(DebugVertex),
  index_buffer:   gpu.DataBuffer(u32),
  vertex_count:   u32,
  index_count:    u32,
  pipeline:       vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  descriptor_set_layout: vk.DescriptorSetLayout,
  // Path rendering buffers
  path_vertex_buffer: gpu.DataBuffer(DebugVertex),
  path_vertex_count:  u32,
  path_pipeline:      vk.Pipeline,
}

// Colors for navmesh visualization
NavMeshColors :: struct {
  mesh:        [4]f32,  // Navmesh polygon color
  bounds:      [4]f32,  // Bounds wireframe color
  path_line:   [4]f32,  // Path line color
  start_point: [4]f32,  // Start point color
  end_point:   [4]f32,  // End point color
}

// Default color scheme
DEFAULT_NAVMESH_COLORS :: NavMeshColors{
  mesh        = {0.0, 0.8, 0.0, 0.3},  // Semi-transparent green
  bounds      = {1.0, 1.0, 1.0, 1.0},  // White wireframe
  path_line   = {1.0, 0.0, 0.0, 1.0},  // Red path
  start_point = {0.0, 1.0, 0.0, 1.0},  // Green start
  end_point   = {1.0, 0.0, 0.0, 1.0},  // Red end
}

// Visualization modes for step-by-step debugging
VisualizationMode :: enum {
  FINAL_MESH,
  HEIGHTFIELD,
  COMPACT_HEIGHTFIELD,
  DISTANCE_FIELD,
  REGIONS,
  CONTOURS,
  POLY_MESH,
}

// Navigation debug system
NavigationDebug :: struct {
  renderer:   DebugRenderer,
  enabled:    bool,
  navmesh:    ^navigation.NavMesh,
  path:       [][3]f32,
  colors:     NavMeshColors,
  mesh_built: bool,
  // Step-by-step visualization data
  vis_mode:   VisualizationMode,
  heightfield_data: ^navigation.Heightfield,
  compact_hf_data: ^navigation.CompactHeightfield,
  contour_data: ^navigation.ContourSet,
  poly_mesh_data: ^navigation.PolyMesh,
}

// Vertex for debug rendering
DebugVertex :: struct {
  position: [3]f32,
  color:    [4]f32,
}

// Initialize navigation debug system
navigation_debug_init :: proc(
  debug: ^NavigationDebug,
  engine: ^Engine,
  navmesh: ^navigation.NavMesh,
  builder: ^navigation.NavMeshBuilder,
) -> bool {
  debug.navmesh = navmesh
  debug.enabled = true
  debug.colors = DEFAULT_NAVMESH_COLORS
  debug.mesh_built = false
  
  // Store debug data from builder
  debug.heightfield_data = builder.debug_heightfield
  debug.compact_hf_data = builder.debug_compact_hf
  debug.contour_data = builder.debug_contours
  debug.poly_mesh_data = builder.debug_poly_mesh
  
  log.infof("Debug data stored: heightfield=%p, compact_hf=%p, contours=%p, poly_mesh=%p", 
    debug.heightfield_data, debug.compact_hf_data, debug.contour_data, debug.poly_mesh_data)
  
  return true
}

// Initialize debug renderer
debug_renderer_init :: proc(
  renderer: ^DebugRenderer,
  gpu_context: ^gpu.GPUContext,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> bool {
  log.info("Initializing navigation debug renderer")

  // Create descriptor set layout
  bindings := []vk.DescriptorSetLayoutBinding{
    {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }

  layout_info := vk.DescriptorSetLayoutCreateInfo{
    sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = u32(len(bindings)),
    pBindings = raw_data(bindings),
  }

  if vk.CreateDescriptorSetLayout(gpu_context.device, &layout_info, nil, &renderer.descriptor_set_layout) != .SUCCESS {
    log.error("Failed to create descriptor set layout")
    return false
  }

  // Create pipeline layout
  push_constant_range := vk.PushConstantRange{
    stageFlags = {.VERTEX},
    offset = 0,
    size = size_of([4][4]f32), // MVP matrix
  }

  pipeline_layout_info := vk.PipelineLayoutCreateInfo{
    sType = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount = 1,
    pSetLayouts = &renderer.descriptor_set_layout,
    pushConstantRangeCount = 1,
    pPushConstantRanges = &push_constant_range,
  }

  if vk.CreatePipelineLayout(gpu_context.device, &pipeline_layout_info, nil, &renderer.pipeline_layout) != .SUCCESS {
    log.error("Failed to create pipeline layout")
    return false
  }

  // Create pipeline with navmesh debug shaders
  if !create_navmesh_debug_pipeline(gpu_context, renderer, color_format, depth_format) {
    log.error("Failed to create navmesh debug pipeline")
    return false
  }

  // Create line rendering pipeline for paths
  if !create_path_debug_pipeline(gpu_context, renderer, color_format, depth_format) {
    log.error("Failed to create path debug pipeline")
    return false
  }

  renderer.is_initialized = true

  log.info("Navigation debug renderer initialized successfully")
  return true
}

// Create the navmesh debug pipeline
create_navmesh_debug_pipeline :: proc(
  gpu_context: ^gpu.GPUContext,
  renderer: ^DebugRenderer,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> bool {
  // Load shaders
  vert_shader_module, vert_result := gpu.create_shader_module(gpu_context, SHADER_NAVMESH_DEBUG_VERT)
  if vert_result != .SUCCESS {
    log.error("Failed to load navmesh debug vertex shader")
    return false
  }
  defer vk.DestroyShaderModule(gpu_context.device, vert_shader_module, nil)

  frag_shader_module, frag_result := gpu.create_shader_module(gpu_context, SHADER_NAVMESH_DEBUG_FRAG)
  if frag_result != .SUCCESS {
    log.error("Failed to load navmesh debug fragment shader")
    return false
  }
  defer vk.DestroyShaderModule(gpu_context.device, frag_shader_module, nil)

  // Shader stages
  shader_stages := [?]vk.PipelineShaderStageCreateInfo{
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_shader_module,
      pName = "main",
    },
  }

  // Dynamic state
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo{
    sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates = raw_data(dynamic_states[:]),
  }

  // Vertex input
  vertex_binding := vk.VertexInputBindingDescription{
    binding = 0,
    stride = size_of(DebugVertex),
    inputRate = .VERTEX,
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription{
    { // position
      binding = 0,
      location = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(DebugVertex, position)),
    },
    { // color
      binding = 0,
      location = 1,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(DebugVertex, color)),
    },
  }

  vertex_input := vk.PipelineVertexInputStateCreateInfo{
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount = 1,
    pVertexBindingDescriptions = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions = raw_data(vertex_attributes[:]),
  }

  // Input assembly
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
    sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }

  // Viewport state
  viewport_state := vk.PipelineViewportStateCreateInfo{
    sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount = 1,
  }

  // Rasterizer
  rasterizer := vk.PipelineRasterizationStateCreateInfo{
    sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    lineWidth = 1.0,
    cullMode = {.BACK},
    frontFace = .CLOCKWISE,
  }

  // Multisampling
  multisampling := vk.PipelineMultisampleStateCreateInfo{
    sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  // Depth stencil
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo{
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    depthWriteEnable = false,
    depthCompareOp = .LESS,
  }

  // Color blending
  color_blend_attachment := vk.PipelineColorBlendAttachmentState{
    colorWriteMask = {.R, .G, .B, .A},
    blendEnable = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp = .ADD,
  }

  color_blending := vk.PipelineColorBlendStateCreateInfo{
    sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable = false,
    attachmentCount = 1,
    pAttachments = &color_blend_attachment,
  }

  // Rendering info for dynamic rendering
  color_attachment_format := [1]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfoKHR{
    sType = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = raw_data(color_attachment_format[:]),
    depthAttachmentFormat = depth_format,
  }

  // Create pipeline
  pipeline_info := vk.GraphicsPipelineCreateInfo{
    sType = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext = &rendering_info,
    stageCount = len(shader_stages),
    pStages = raw_data(shader_stages[:]),
    pVertexInputState = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState = &multisampling,
    pDepthStencilState = &depth_stencil,
    pColorBlendState = &color_blending,
    pDynamicState = &dynamic_state_info,
    layout = renderer.pipeline_layout,
  }

  if vk.CreateGraphicsPipelines(gpu_context.device, 0, 1, &pipeline_info, nil, &renderer.pipeline) != .SUCCESS {
    log.error("Failed to create navmesh debug graphics pipeline")
    return false
  }

  log.info("Navmesh debug pipeline created successfully")
  return true
}

// Create the path debug pipeline (for line rendering)
create_path_debug_pipeline :: proc(
  gpu_context: ^gpu.GPUContext,
  renderer: ^DebugRenderer,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> bool {
  // Load shaders (reuse the same shaders)
  vert_shader_module, vert_result := gpu.create_shader_module(gpu_context, SHADER_NAVMESH_DEBUG_VERT)
  if vert_result != .SUCCESS {
    log.error("Failed to load path debug vertex shader")
    return false
  }
  defer vk.DestroyShaderModule(gpu_context.device, vert_shader_module, nil)

  frag_shader_module, frag_result := gpu.create_shader_module(gpu_context, SHADER_NAVMESH_DEBUG_FRAG)
  if frag_result != .SUCCESS {
    log.error("Failed to load path debug fragment shader")
    return false
  }
  defer vk.DestroyShaderModule(gpu_context.device, frag_shader_module, nil)

  // Shader stages
  shader_stages := [?]vk.PipelineShaderStageCreateInfo{
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_shader_module,
      pName = "main",
    },
  }

  // Dynamic state
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo{
    sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates = raw_data(dynamic_states[:]),
  }

  // Vertex input (same as navmesh)
  vertex_binding := vk.VertexInputBindingDescription{
    binding = 0,
    stride = size_of(DebugVertex),
    inputRate = .VERTEX,
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription{
    { // position
      binding = 0,
      location = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(DebugVertex, position)),
    },
    { // color
      binding = 0,
      location = 1,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(DebugVertex, color)),
    },
  }

  vertex_input := vk.PipelineVertexInputStateCreateInfo{
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount = 1,
    pVertexBindingDescriptions = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions = raw_data(vertex_attributes[:]),
  }

  // Input assembly - use LINE_STRIP for path rendering
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
    sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .LINE_STRIP,
  }

  // Viewport state
  viewport_state := vk.PipelineViewportStateCreateInfo{
    sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount = 1,
  }

  // Rasterizer
  rasterizer := vk.PipelineRasterizationStateCreateInfo{
    sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    lineWidth = 3.0, // Thicker lines for path visibility
  }

  // Multisampling
  multisampling := vk.PipelineMultisampleStateCreateInfo{
    sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  // Depth stencil
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo{
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    depthWriteEnable = false, // Don't write depth for lines
    depthCompareOp = .LESS_OR_EQUAL, // Allow lines to show over navmesh
  }

  // Color blending (same as navmesh)
  color_blend_attachment := vk.PipelineColorBlendAttachmentState{
    colorWriteMask = {.R, .G, .B, .A},
    blendEnable = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp = .ADD,
  }

  color_blending := vk.PipelineColorBlendStateCreateInfo{
    sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable = false,
    attachmentCount = 1,
    pAttachments = &color_blend_attachment,
  }

  // Rendering info for dynamic rendering
  color_attachment_format := [1]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfoKHR{
    sType = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = raw_data(color_attachment_format[:]),
    depthAttachmentFormat = depth_format,
  }

  // Create pipeline
  pipeline_info := vk.GraphicsPipelineCreateInfo{
    sType = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext = &rendering_info,
    stageCount = len(shader_stages),
    pStages = raw_data(shader_stages[:]),
    pVertexInputState = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState = &multisampling,
    pDepthStencilState = &depth_stencil,
    pColorBlendState = &color_blending,
    pDynamicState = &dynamic_state_info,
    layout = renderer.pipeline_layout,
  }

  if vk.CreateGraphicsPipelines(gpu_context.device, 0, 1, &pipeline_info, nil, &renderer.path_pipeline) != .SUCCESS {
    log.error("Failed to create path debug graphics pipeline")
    return false
  }

  log.info("Path debug pipeline created successfully")
  return true
}

navigation_debug_init_renderer :: proc(
  debug: ^NavigationDebug,
  engine: ^Engine,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> bool {
  if debug.renderer.is_initialized do return true

  if !debug_renderer_init(
    &debug.renderer,
    &engine.gpu_context,
    color_format,
    depth_format,
  ) {
    log.error("Failed to initialize navigation debug renderer")
    return false
  }

  return true
}

// Build debug mesh from navmesh or intermediate data
build_debug_mesh :: proc(
  renderer: ^DebugRenderer,
  gpu_context: ^gpu.GPUContext,
  debug: ^NavigationDebug,
) -> bool {
  vertices := make([dynamic]DebugVertex)
  indices := make([dynamic]u32)
  defer delete(vertices)
  defer delete(indices)

  // Generate geometry based on current visualization mode
  switch debug.vis_mode {
  case .FINAL_MESH:
    if debug.navmesh == nil {
      log.warn("Cannot build debug mesh: navmesh is nil")
      return false
    }
    generate_navmesh_debug_geometry(debug.navmesh, debug.colors, &vertices, &indices)
    
  case .HEIGHTFIELD:
    if debug.heightfield_data == nil {
      log.warn("No heightfield data to visualize")
      return false
    }
    log.infof("Generating heightfield debug geometry for heightfield %p", debug.heightfield_data)
    generate_heightfield_debug_geometry(debug.heightfield_data, debug.colors, &vertices, &indices)
    log.infof("Generated %d vertices, %d indices for heightfield", len(vertices), len(indices))
    
  case .COMPACT_HEIGHTFIELD, .DISTANCE_FIELD:
    if debug.compact_hf_data == nil {
      log.warn("No compact heightfield data to visualize")
      return false
    }
    generate_compact_heightfield_debug_geometry(debug.compact_hf_data, debug.colors, &vertices, &indices)
    
  case .REGIONS:
    if debug.compact_hf_data == nil {
      log.warn("No compact heightfield data to visualize regions")
      return false
    }
    generate_regions_debug_geometry(debug.compact_hf_data, debug.colors, &vertices, &indices)
    
  case .CONTOURS:
    if debug.contour_data == nil {
      log.warn("No contour data to visualize")
      return false
    }
    generate_contour_debug_geometry(debug.contour_data, debug.colors, &vertices, &indices)
    
  case .POLY_MESH:
    if debug.poly_mesh_data == nil {
      log.warn("No poly mesh data to visualize")
      return false
    }
    generate_polymesh_debug_geometry(debug.poly_mesh_data, debug.colors, &vertices, &indices)
  }

  if len(vertices) == 0 {
    log.warn("No debug geometry generated for mode: %v", debug.vis_mode)
    return false
  }

  // Clean up old buffers
  if renderer.vertex_count > 0 {
    gpu.data_buffer_deinit(gpu_context, &renderer.vertex_buffer)
    gpu.data_buffer_deinit(gpu_context, &renderer.index_buffer)
  }

  // Create vertex buffer
  vertex_buffer, vert_result := gpu.create_local_buffer(
    gpu_context,
    DebugVertex,
    len(vertices),
    {.VERTEX_BUFFER},
    raw_data(vertices),
  )
  if vert_result != .SUCCESS {
    log.error("Failed to create vertex buffer")
    return false
  }
  renderer.vertex_buffer = vertex_buffer

  // Create index buffer
  index_buffer, idx_result := gpu.create_local_buffer(
    gpu_context,
    u32,
    len(indices),
    {.INDEX_BUFFER},
    raw_data(indices),
  )
  if idx_result != .SUCCESS {
    log.error("Failed to create index buffer")
    return false
  }
  renderer.index_buffer = index_buffer

  renderer.vertex_count = u32(len(vertices))
  renderer.index_count = u32(len(indices))

  log.infof("Debug mesh built for mode %v: %d vertices, %d indices", debug.vis_mode, len(vertices), len(indices))
  return true
}

// Generate debug geometry from navmesh
generate_navmesh_debug_geometry :: proc(
  navmesh: ^navigation.NavMesh,
  colors: NavMeshColors,
  vertices: ^[dynamic]DebugVertex,
  indices: ^[dynamic]u32,
) {
  vertex_offset: u32 = 0

  // Iterate through all tiles
  for tile_idx in 0..<navmesh.max_tiles {
    tile := &navmesh.tiles[tile_idx]
    if tile.header == nil do continue

    // Iterate through polygons in tile
    for poly_idx in 0..<tile.header.poly_count {
      poly := &tile.polys[poly_idx]
      if poly.vert_count < 3 do continue

      // Add polygon vertices
      base_vertex := vertex_offset
      for i in 0..<poly.vert_count {
        vert_idx := poly.verts[i]
        if vert_idx >= u16(tile.header.vert_count) do continue

        vert_pos := [3]f32{
          tile.verts[vert_idx * 3 + 0],
          tile.verts[vert_idx * 3 + 1] + NAVMESH_DEBUG_ELEVATION,
          tile.verts[vert_idx * 3 + 2],
        }

        append(vertices, DebugVertex{
          position = vert_pos,
          color = colors.mesh,
        })
        vertex_offset += 1
      }

      // Generate triangle fan indices for polygon
      for i in 1..<poly.vert_count - 1 {
        append(indices, base_vertex)
        append(indices, base_vertex + u32(i))
        append(indices, base_vertex + u32(i + 1))
      }
    }
  }
}

// Generate debug geometry for heightfield visualization
generate_heightfield_debug_geometry :: proc(
  hf: ^navigation.Heightfield,
  colors: NavMeshColors,
  vertices: ^[dynamic]DebugVertex,
  indices: ^[dynamic]u32,
) {
  if hf == nil do return
  
  log.infof("Heightfield: width=%d, height=%d, spans=%p", hf.width, hf.height, hf.spans)
  
  if hf.spans == nil {
    log.warn("Heightfield spans is nil, cannot visualize")
    return
  }
  
  vertex_offset: u32 = 0
  
  // Visualize each span in the heightfield
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      span := hf.spans[idx]
      
      for span != nil {
        // Calculate world position
        wx := hf.bmin.x + f32(x) * hf.cs
        wz := hf.bmin.z + f32(z) * hf.cs
        wy_bottom := hf.bmin.y + f32(span.smin) * hf.ch
        wy_top := hf.bmin.y + f32(span.smax) * hf.ch + NAVMESH_DEBUG_ELEVATION
        
        // Choose color based on area type
        color := colors.mesh
        if span.area == navigation.NULL_AREA {
          color = {0.8, 0.2, 0.2, 0.5}  // Red for obstacles
        } else if span.area == navigation.WALKABLE_AREA {
          color = {0.2, 0.8, 0.2, 0.5}  // Green for walkable
        }
        
        // Create a quad for the top of the span
        base_vertex := vertex_offset
        append(vertices, DebugVertex{[3]f32{wx, wy_top, wz}, color})
        append(vertices, DebugVertex{[3]f32{wx + hf.cs, wy_top, wz}, color})
        append(vertices, DebugVertex{[3]f32{wx + hf.cs, wy_top, wz + hf.cs}, color})
        append(vertices, DebugVertex{[3]f32{wx, wy_top, wz + hf.cs}, color})
        vertex_offset += 4
        
        // Create quad indices
        append(indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
        append(indices, base_vertex + 0, base_vertex + 2, base_vertex + 3)
        
        span = span.next
      }
    }
  }
}

// Generate debug geometry for compact heightfield visualization
generate_compact_heightfield_debug_geometry :: proc(
  chf: ^navigation.CompactHeightfield,
  colors: NavMeshColors,
  vertices: ^[dynamic]DebugVertex,
  indices: ^[dynamic]u32,
) {
  if chf == nil do return
  
  vertex_offset: u32 = 0
  
  // Visualize each span in the compact heightfield
  for y in 0..<chf.height {
    for x in 0..<chf.width {
      c := &chf.cells[x + y * chf.width]
      cellIndex, cellCount := navigation.unpack_compact_cell(c.index)
      
      for i in cellIndex..<cellIndex + u32(cellCount) {
        s := &chf.spans[i]
        area := chf.areas[i]
        
        // Calculate world position
        wx := chf.bmin.x + f32(x) * chf.cs
        wz := chf.bmin.z + f32(y) * chf.cs
        wy := chf.bmin.y + f32(s.y) * chf.ch + NAVMESH_DEBUG_ELEVATION
        
        // Choose color based on area or distance field
        color := colors.mesh
        if chf.dist != nil && i < u32(len(chf.dist)) {
          // Color by distance field
          t := f32(chf.dist[i]) / 255.0
          color = {1.0 - t, t, 0.0, 0.7}
        } else if area == navigation.NULL_AREA {
          color = {0.8, 0.2, 0.2, 0.5}
        } else {
          color = {0.2, 0.8, 0.2, 0.5}
        }
        
        // Create a quad for the span
        base_vertex := vertex_offset
        append(vertices, DebugVertex{[3]f32{wx, wy, wz}, color})
        append(vertices, DebugVertex{[3]f32{wx + chf.cs, wy, wz}, color})
        append(vertices, DebugVertex{[3]f32{wx + chf.cs, wy, wz + chf.cs}, color})
        append(vertices, DebugVertex{[3]f32{wx, wy, wz + chf.cs}, color})
        vertex_offset += 4
        
        // Create quad indices
        append(indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
        append(indices, base_vertex + 0, base_vertex + 2, base_vertex + 3)
      }
    }
  }
}

// Generate debug geometry for regions
generate_regions_debug_geometry :: proc(
  chf: ^navigation.CompactHeightfield,
  colors: NavMeshColors,
  vertices: ^[dynamic]DebugVertex,
  indices: ^[dynamic]u32,
) {
  if chf == nil do return
  
  vertex_offset: u32 = 0
  
  // Create a color palette for different regions
  region_colors := [20][4]f32{
    {0.8, 0.2, 0.2, 0.5},
    {0.2, 0.8, 0.2, 0.5},
    {0.2, 0.2, 0.8, 0.5},
    {0.8, 0.8, 0.2, 0.5},
    {0.8, 0.2, 0.8, 0.5},
    {0.2, 0.8, 0.8, 0.5},
    {0.6, 0.4, 0.2, 0.5},
    {0.4, 0.6, 0.8, 0.5},
    {0.8, 0.4, 0.6, 0.5},
    {0.4, 0.8, 0.4, 0.5},
    // Repeat pattern with variations
    {0.9, 0.3, 0.3, 0.5},
    {0.3, 0.9, 0.3, 0.5},
    {0.3, 0.3, 0.9, 0.5},
    {0.9, 0.9, 0.3, 0.5},
    {0.9, 0.3, 0.9, 0.5},
    {0.3, 0.9, 0.9, 0.5},
    {0.7, 0.5, 0.3, 0.5},
    {0.5, 0.7, 0.9, 0.5},
    {0.9, 0.5, 0.7, 0.5},
    {0.5, 0.9, 0.5, 0.5},
  }
  
  // Visualize regions
  for y in 0..<chf.height {
    for x in 0..<chf.width {
      c := &chf.cells[x + y * chf.width]
      cellIndex, cellCount := navigation.unpack_compact_cell(c.index)
      
      for i in cellIndex..<cellIndex + u32(cellCount) {
        s := &chf.spans[i]
        
        if s.reg == 0 do continue
        
        // Calculate world position
        wx := chf.bmin.x + f32(x) * chf.cs
        wz := chf.bmin.z + f32(y) * chf.cs
        wy := chf.bmin.y + f32(s.y) * chf.ch + NAVMESH_DEBUG_ELEVATION
        
        // Choose color based on region ID
        color := region_colors[s.reg % 20]
        
        // Create a quad for the span
        base_vertex := vertex_offset
        append(vertices, DebugVertex{[3]f32{wx, wy, wz}, color})
        append(vertices, DebugVertex{[3]f32{wx + chf.cs, wy, wz}, color})
        append(vertices, DebugVertex{[3]f32{wx + chf.cs, wy, wz + chf.cs}, color})
        append(vertices, DebugVertex{[3]f32{wx, wy, wz + chf.cs}, color})
        vertex_offset += 4
        
        // Create quad indices
        append(indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
        append(indices, base_vertex + 0, base_vertex + 2, base_vertex + 3)
      }
    }
  }
}

// Render debug mesh
render_debug_mesh :: proc(
  renderer: ^DebugRenderer,
  cmd: vk.CommandBuffer,
  mvp_matrix: matrix[4,4]f32,
) {
  if !renderer.is_initialized || renderer.vertex_count == 0 do return

  // Bind pipeline
  vk.CmdBindPipeline(cmd, .GRAPHICS, renderer.pipeline)

  // Push MVP matrix
  push_data := mvp_matrix
  vk.CmdPushConstants(cmd, renderer.pipeline_layout, {.VERTEX}, 0, size_of(push_data), &push_data)

  // Bind vertex buffer
  vertex_buffers := []vk.Buffer{renderer.vertex_buffer.buffer}
  offsets := []vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(cmd, 0, 1, raw_data(vertex_buffers), raw_data(offsets))

  // Bind index buffer
  vk.CmdBindIndexBuffer(cmd, renderer.index_buffer.buffer, 0, .UINT32)

  // Draw
  vk.CmdDrawIndexed(cmd, renderer.index_count, 1, 0, 0, 0)
}

// Build path vertex buffer
build_path_buffer :: proc(
  renderer: ^DebugRenderer,
  gpu_context: ^gpu.GPUContext,
  path: [][3]f32,
  start_pos: [3]f32,
  color: [4]f32,
) -> bool {
  if len(path) == 0 {
    renderer.path_vertex_count = 0
    return true
  }

  // Create vertices for complete path (start + waypoints)
  path_vertices := make([dynamic]DebugVertex, 0, len(path) + 1)
  defer delete(path_vertices)

  // Add start position first
  elevated_start := [3]f32{start_pos.x, start_pos.y + PATH_DEBUG_ELEVATION, start_pos.z}
  append(&path_vertices, DebugVertex{
    position = elevated_start,
    color = color,
  })

  // Add all waypoints
  for point in path {
    elevated_point := [3]f32{point.x, point.y + PATH_DEBUG_ELEVATION, point.z}
    append(&path_vertices, DebugVertex{
      position = elevated_point,
      color = color,
    })
  }

  // Create/update path vertex buffer
  if renderer.path_vertex_count > 0 {
    // Clean up existing buffer
    gpu.data_buffer_deinit(gpu_context, &renderer.path_vertex_buffer)
  }

  path_buffer, result := gpu.create_local_buffer(
    gpu_context,
    DebugVertex,
    len(path_vertices),
    {.VERTEX_BUFFER},
    raw_data(path_vertices),
  )
  if result != .SUCCESS {
    log.error("Failed to create path vertex buffer")
    return false
  }

  renderer.path_vertex_buffer = path_buffer
  renderer.path_vertex_count = u32(len(path_vertices))
  return true
}

// Render path
render_path :: proc(
  renderer: ^DebugRenderer,
  cmd: vk.CommandBuffer,
  mvp_matrix: matrix[4,4]f32,
) {
  if renderer.path_vertex_count == 0 do return

  // Bind path pipeline
  vk.CmdBindPipeline(cmd, .GRAPHICS, renderer.path_pipeline)

  // Push MVP matrix
  push_data := mvp_matrix
  vk.CmdPushConstants(cmd, renderer.pipeline_layout, {.VERTEX}, 0, size_of(push_data), &push_data)

  // Bind vertex buffer
  vertex_buffers := []vk.Buffer{renderer.path_vertex_buffer.buffer}
  offsets := []vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(cmd, 0, 1, raw_data(vertex_buffers), raw_data(offsets))

  // Draw line strip
  vk.CmdDraw(cmd, renderer.path_vertex_count, 1, 0, 0)
}

navigation_debug_deinit :: proc(debug: ^NavigationDebug, engine: ^Engine) {
  if debug.renderer.is_initialized {
    debug_renderer_destroy(&debug.renderer, &engine.gpu_context)
  }
  delete(debug.path)
  debug.enabled = false
  debug.mesh_built = false
}

navigation_debug_set_path :: proc(debug: ^NavigationDebug, engine: ^Engine, path: [][3]f32, start_pos: [3]f32) {
  delete(debug.path)
  debug.path = make([][3]f32, len(path))
  copy(debug.path, path)

  // Build path vertex buffer for rendering
  if debug.renderer.is_initialized {
    build_path_buffer(&debug.renderer, &engine.gpu_context, path, start_pos, debug.colors.path_line)
  }
}

navigation_debug_render :: proc(
  debug: ^NavigationDebug,
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  camera_view_matrix: linalg.Matrix4f32,
  camera_proj_matrix: linalg.Matrix4f32,
) {
  if !debug.enabled || debug.navmesh == nil do return

  // Get the main render target
  main_render_target := resource.get(
    engine.warehouse.render_targets,
    engine.main_render_target,
  )
  if main_render_target == nil do return

  // Begin dynamic rendering
  color_attachment := vk.RenderingAttachmentInfoKHR{
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = resource.get(engine.warehouse.image_2d_buffers, render_target_final_image(main_render_target, engine.frame_index)).view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,  // Load existing content
    storeOp = .STORE,
  }

  depth_attachment := vk.RenderingAttachmentInfoKHR{
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = resource.get(engine.warehouse.image_2d_buffers, render_target_depth_texture(main_render_target, engine.frame_index)).view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,  // Load existing depth
    storeOp = .STORE,
  }

  render_info := vk.RenderingInfoKHR{
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = main_render_target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRenderingKHR(command_buffer, &render_info)

  // Set viewport and scissor
  viewport := vk.Viewport{
    x = 0,
    y = f32(main_render_target.extent.height),
    width = f32(main_render_target.extent.width),
    height = -f32(main_render_target.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D{
    extent = main_render_target.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Build debug mesh if needed
  if !debug.mesh_built {
    if build_debug_mesh(
      &debug.renderer,
      &engine.gpu_context,
      debug,
    ) {
      debug.mesh_built = true
    } else {
      log.error("Failed to build debug mesh")
      vk.CmdEndRenderingKHR(command_buffer)
      return
    }
  }

  // Render the navigation mesh
  mvp_matrix := camera_proj_matrix * camera_view_matrix
  render_debug_mesh(
    &debug.renderer,
    command_buffer,
    mvp_matrix,
  )

  // Render the path if one exists
  if len(debug.path) > 0 {
    render_path(
      &debug.renderer,
      command_buffer,
      mvp_matrix,
    )
  }

  // End dynamic rendering
  vk.CmdEndRenderingKHR(command_buffer)
}

navigation_debug_toggle :: proc(debug: ^NavigationDebug) {
  debug.enabled = !debug.enabled
  log.infof("Navigation debug rendering: %s", debug.enabled ? "enabled" : "disabled")
}

navigation_debug_set_colors :: proc(debug: ^NavigationDebug, colors: NavMeshColors) {
  debug.colors = colors
  debug.mesh_built = false  // Force rebuild with new colors
}

navigation_debug_update_navmesh :: proc(debug: ^NavigationDebug, navmesh: ^navigation.NavMesh) {
  debug.navmesh = navmesh
  debug.mesh_built = false  // Force rebuild with new navmesh
}

navigation_debug_force_rebuild :: proc(debug: ^NavigationDebug) {
  debug.mesh_built = false
}

// Cleanup debug renderer
debug_renderer_destroy :: proc(renderer: ^DebugRenderer, gpu_context: ^gpu.GPUContext) {
  if !renderer.is_initialized do return

  gpu.data_buffer_deinit(gpu_context, &renderer.vertex_buffer)
  gpu.data_buffer_deinit(gpu_context, &renderer.index_buffer)

  // Clean up path buffer if it exists
  if renderer.path_vertex_count > 0 {
    gpu.data_buffer_deinit(gpu_context, &renderer.path_vertex_buffer)
  }

  vk.DestroyPipeline(gpu_context.device, renderer.pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, renderer.path_pipeline, nil)
  vk.DestroyPipelineLayout(gpu_context.device, renderer.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gpu_context.device, renderer.descriptor_set_layout, nil)

  renderer.is_initialized = false
  log.info("Navigation debug renderer destroyed")
}

// Generate debug geometry for contours
generate_contour_debug_geometry :: proc(
  cset: ^navigation.ContourSet,
  colors: NavMeshColors,
  vertices: ^[dynamic]DebugVertex,
  indices: ^[dynamic]u32,
) {
  if cset == nil do return
  
  vertex_offset: u32 = 0
  
  // Create a color palette for different contours
  contour_colors := [10][4]f32{
    {1.0, 0.0, 0.0, 0.8},
    {0.0, 1.0, 0.0, 0.8},
    {0.0, 0.0, 1.0, 0.8},
    {1.0, 1.0, 0.0, 0.8},
    {1.0, 0.0, 1.0, 0.8},
    {0.0, 1.0, 1.0, 0.8},
    {1.0, 0.5, 0.0, 0.8},
    {0.5, 1.0, 0.0, 0.8},
    {0.0, 0.5, 1.0, 0.8},
    {1.0, 0.0, 0.5, 0.8},
  }
  
  // Draw each contour
  for i in 0..<cset.nconts {
    cont := &cset.conts[i]
    color := contour_colors[i % 10]
    
    // Draw simplified contour as line loop
    if cont.nverts > 0 {
      base_vertex := vertex_offset
      
      // Add vertices
      for j in 0..<cont.nverts {
        wx := f32(cont.verts[j*4 + 0]) * cset.cs + cset.bmin.x
        wy := f32(cont.verts[j*4 + 1]) * cset.ch + cset.bmin.y + NAVMESH_DEBUG_ELEVATION * 2
        wz := f32(cont.verts[j*4 + 2]) * cset.cs + cset.bmin.z
        
        append(vertices, DebugVertex{[3]f32{wx, wy, wz}, color})
        vertex_offset += 1
      }
      
      // Create line indices
      for j in 0..<cont.nverts-1 {
        append(indices, base_vertex + u32(j), base_vertex + u32(j) + 1, base_vertex + u32(j))
      }
      // Close the loop
      if cont.nverts > 2 {
        append(indices, base_vertex + u32(cont.nverts-1), base_vertex, base_vertex)
      }
    }
  }
}

// Generate debug geometry for polygon mesh
generate_polymesh_debug_geometry :: proc(
  pmesh: ^navigation.PolyMesh,
  colors: NavMeshColors,
  vertices: ^[dynamic]DebugVertex,
  indices: ^[dynamic]u32,
) {
  if pmesh == nil do return
  
  vertex_offset: u32 = 0
  
  // Add all vertices
  base_vertex := vertex_offset
  for i in 0..<pmesh.nverts {
    idx := i * 3
    wx := pmesh.bmin.x + f32(pmesh.verts[idx + 0]) * pmesh.cs
    wy := pmesh.bmin.y + f32(pmesh.verts[idx + 1]) * pmesh.ch + NAVMESH_DEBUG_ELEVATION
    wz := pmesh.bmin.z + f32(pmesh.verts[idx + 2]) * pmesh.cs
    
    append(vertices, DebugVertex{[3]f32{wx, wy, wz}, colors.mesh})
    vertex_offset += 1
  }
  
  // Create polygons
  for i in 0..<pmesh.npolys {
    p_base := i * pmesh.nvp * 2
    
    // Count valid vertices
    vert_count := 0
    for j in 0..<pmesh.nvp {
      if pmesh.polys[p_base + i32(j)] == 0xffff do break
      vert_count += 1
    }
    
    // Create triangle fan for polygon
    if vert_count >= 3 {
      v0 := base_vertex + u32(pmesh.polys[p_base])
      for j in 1..<vert_count-1 {
        v1 := base_vertex + u32(pmesh.polys[p_base + i32(j)])
        v2 := base_vertex + u32(pmesh.polys[p_base + i32(j+1)])
        append(indices, v0, v1, v2)
      }
    }
  }
}

// Add function to switch visualization mode
navigation_debug_set_mode :: proc(debug: ^NavigationDebug, mode: VisualizationMode) {
  debug.vis_mode = mode
  debug.mesh_built = false  // Force rebuild with new mode
  log.infof("Navigation debug mode changed to: %v", mode)
}

// Add function to cycle through visualization modes
navigation_debug_cycle_mode :: proc(debug: ^NavigationDebug) {
  // Only include working modes for now
  modes := []VisualizationMode{
    .FINAL_MESH,
    .COMPACT_HEIGHTFIELD,
  }
  
  current_idx := 0
  for mode, i in modes {
    if mode == debug.vis_mode {
      current_idx = i
      break
    }
  }
  
  next_idx := (current_idx + 1) % len(modes)
  debug.vis_mode = modes[next_idx]
  debug.mesh_built = false
  log.infof("Navigation debug mode changed to: %v", debug.vis_mode)
}

// Store intermediate build data for visualization
navigation_debug_store_build_data :: proc(
  debug: ^NavigationDebug,
  hf: ^navigation.Heightfield,
  chf: ^navigation.CompactHeightfield,
  cset: ^navigation.ContourSet,
  pmesh: ^navigation.PolyMesh,
) {
  debug.heightfield_data = hf
  debug.compact_hf_data = chf
  debug.contour_data = cset
  debug.poly_mesh_data = pmesh
}
