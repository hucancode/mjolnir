package gpu

import vk "vendor:vulkan"

// Pipeline state creation helpers that provide sensible defaults for common patterns.
// These reduce boilerplate while remaining explicit about what's being configured.

// Creates standard rasterization state with common defaults.
// Default: FILL mode, BACK face culling, COUNTER_CLOCKWISE front face, lineWidth 1.0
create_standard_rasterizer :: proc(
  cull_mode: vk.CullModeFlags = {.BACK},
  polygon_mode: vk.PolygonMode = .FILL,
  front_face: vk.FrontFace = .COUNTER_CLOCKWISE,
  line_width: f32 = 1.0,
) -> vk.PipelineRasterizationStateCreateInfo {
  return {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = polygon_mode,
    cullMode    = cull_mode,
    frontFace   = front_face,
    lineWidth   = line_width,
  }
}

// Creates standard input assembly state for triangle lists.
// Default: TRIANGLE_LIST topology (most common for 3D rendering)
create_standard_input_assembly :: proc(
  topology: vk.PrimitiveTopology = .TRIANGLE_LIST,
) -> vk.PipelineInputAssemblyStateCreateInfo {
  return {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = topology,
  }
}

// Creates standard multisampling state with 1x MSAA (no multisampling).
// 1x MSAA is the most common configuration for deferred rendering.
create_standard_multisampling :: proc() -> vk.PipelineMultisampleStateCreateInfo {
  return {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
}

// Standard dynamic states used by most pipelines.
// Viewport and scissor are dynamic to support window resizing.
STANDARD_DYNAMIC_STATES := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}

// Creates dynamic state CreateInfo from the provided states array.
// For the common case, use STANDARD_DYNAMIC_STATES constant.
// For additional states, create your own array combining base + extras.
create_dynamic_state :: proc(
  states: []vk.DynamicState,
) -> vk.PipelineDynamicStateCreateInfo {
  return {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(states)),
    pDynamicStates    = raw_data(states),
  }
}
