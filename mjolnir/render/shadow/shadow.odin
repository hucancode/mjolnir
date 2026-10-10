package shadow

import "../bindless"
import "../../geometry"
import "../mesh"
import "../gpu"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

// FRUSTUM: spot/directional lights, frustum-culled into a 2D depth map.
// SPHERE: point lights, sphere-culled into a cube depth map in one pass.
Kind :: enum {
  FRUSTUM,
  SPHERE,
}

// include_flags / exclude_flags use the bit layout of render.NodeFlagSet; the
// caller transmutes its NodeFlagSet to u32 so this package stays unaware of
// render's NodeFlag enum.
CullPushConstants :: struct($Shape: typeid) {
  shape:         Shape,
  node_count:    u32,
  max_draws:     u32,
  include_flags: u32,
  exclude_flags: u32,
}

Sphere :: struct {
  center: [3]f32,
  radius: f32,
}

FrustumDepthPushConstants :: struct {
  view_projection: matrix[4, 4]f32,
}

SphereDepthPushConstants :: struct {
  projection:     matrix[4, 4]f32,
  light_position: [3]f32,
  near_plane:     f32,
  far_plane:      f32,
}

@(private = "file")
KindDesc :: struct {
  cull:              []u8,
  cull_push_size:    u32,
  depth_vert:        []u8,
  depth_geom:        []u8,
  depth_frag:        []u8,
  depth_push_stages: vk.ShaderStageFlags,
  depth_push_size:   u32,
  front_face:        vk.FrontFace,
}

@(private = "file")
KINDS := [Kind]KindDesc {
  .FRUSTUM = {
    cull = #load("../../shader/shadow/cull.spv"),
    cull_push_size = size_of(CullPushConstants([6][4]f32)),
    depth_vert = #load("../../shader/shadow/vert.spv"),
    depth_push_stages = {.VERTEX},
    depth_push_size = size_of(FrustumDepthPushConstants),
    front_face = .COUNTER_CLOCKWISE,
  },
  .SPHERE = {
    cull = #load("../../shader/shadow_spherical/cull.spv"),
    cull_push_size = size_of(CullPushConstants(Sphere)),
    depth_vert = #load("../../shader/shadow_spherical/vert.spv"),
    depth_geom = #load("../../shader/shadow_spherical/geom.spv"),
    depth_frag = #load("../../shader/shadow_spherical/frag.spv"),
    depth_push_stages = {.VERTEX, .GEOMETRY, .FRAGMENT},
    depth_push_size = size_of(SphereDepthPushConstants),
    // Pairs with the clip-space X flip in record_sphere.
    front_face = .CLOCKWISE,
  },
}

// Depth passes bind every mesh set except the camera.
SHADOW_SETS :: bindless.MESH_SETS - {.CAMERA}

System :: struct {
  max_draws:              u32,
  shadow_map_size:        u32,
  include_flags:          u32,
  exclude_flags:          u32,
  cull_descriptor_layout: vk.DescriptorSetLayout,
  cull_pipeline_layouts:  [Kind]vk.PipelineLayout,
  cull_pipelines:         [Kind]vk.Pipeline,
  depth_pipeline_layouts: [Kind]vk.PipelineLayout,
  depth_pipelines:        [Kind]vk.Pipeline,
}

// Cached per-frame shadow math for one light. Computed once per frame and
// reused by depth dispatch (for frustum culling + view_projection push) and
// the deferred lighting pass (for shadow sampling). Point lights only use
// `projection` + `near/far`; the cube face views are derived inside the
// sphere depth pass itself.
ShadowFrameInfo :: struct {
  view_projection: matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  near, far:       f32,
}

safe_normalize :: proc(v: [3]f32, fallback: [3]f32) -> [3]f32 {
  len_sq := linalg.dot(v, v)
  if len_sq < 1e-6 do return fallback
  return linalg.normalize(v)
}

make_light_view :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  forward := safe_normalize(direction, {0, -1, 0})
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(forward, up)) > 0.95 {
    up = {0, 0, 1}
  }
  target := position + forward
  return linalg.matrix4_look_at(position, target, up)
}

matrices_spot :: proc(
  position, direction: [3]f32,
  radius, angle_outer: f32,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius)
  view = make_light_view(position, direction)
  fovy := max(angle_outer * 2.0, 0.001)
  projection = geometry.make_perspective_matrix(fovy, 1.0, near, far)
  return
}

matrices_directional :: proc(
  position, direction: [3]f32,
  radius: f32,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius * 2.0)
  camera_pos := position - direction * radius
  view = make_light_view(camera_pos, direction)
  half_extent := max(radius, 0.5)
  projection = geometry.make_ortho_matrix(
    -half_extent,
    half_extent,
    -half_extent,
    half_extent,
    near,
    far,
  )
  return
}

projection_point :: proc(
  radius: f32,
) -> (
  projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius)
  projection = geometry.make_perspective_matrix_lh(
    f32(math.PI * 0.5),
    1.0,
    near,
    far,
  )
  return
}

init :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  scene: bindless.SceneBindings,
  max_draws: u32,
  shadow_map_size: u32,
  include_flags: u32,
  exclude_flags: u32,
) -> (
  ret: vk.Result,
) {
  defer if ret != .SUCCESS do shutdown(self, gctx)
  self.max_draws = max_draws
  self.shadow_map_size = shadow_map_size
  self.include_flags = include_flags
  self.exclude_flags = exclude_flags
  self.cull_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}}, // nodes
    {.STORAGE_BUFFER, {.COMPUTE}}, // meshes
    {.STORAGE_BUFFER, {.COMPUTE}}, // draw_count
    {.STORAGE_BUFFER, {.COMPUTE}}, // draw_commands
  ) or_return
  vertex_bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(mesh.Vertex), inputRate = .VERTEX},
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(mesh.Vertex, position)),
    },
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(vertex_bindings),
    pVertexBindingDescriptions      = raw_data(vertex_bindings[:]),
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }
  for desc, kind in KINDS {
    self.cull_pipeline_layouts[kind] = gpu.create_pipeline_layout(
      gctx,
      vk.PushConstantRange {
        stageFlags = {.COMPUTE},
        size = desc.cull_push_size,
      },
      self.cull_descriptor_layout,
    ) or_return
    cull_shader := gpu.create_shader_module(gctx.device, desc.cull) or_return
    defer vk.DestroyShaderModule(gctx.device, cull_shader, nil)
    self.cull_pipelines[kind] = gpu.create_compute_pipeline(
      gctx,
      cull_shader,
      self.cull_pipeline_layouts[kind],
    ) or_return
    self.depth_pipeline_layouts[kind] = bindless.create_scene_pipeline_layout(
      gctx,
      scene,
      SHADOW_SETS,
      {stageFlags = desc.depth_push_stages, size = desc.depth_push_size},
    ) or_return
    stage_flags := [3]vk.ShaderStageFlags{{.VERTEX}, {.GEOMETRY}, {.FRAGMENT}}
    modules: [3]vk.ShaderModule
    defer for m in modules do vk.DestroyShaderModule(gctx.device, m, nil)
    stages: [3]vk.PipelineShaderStageCreateInfo
    stage_count: u32
    for code, i in ([3][]u8{desc.depth_vert, desc.depth_geom, desc.depth_frag}) {
      if code == nil do continue
      modules[i] = gpu.create_shader_module(gctx.device, code) or_return
      stages[stage_count] = {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = stage_flags[i],
        module = modules[i],
        pName  = "main",
      }
      stage_count += 1
    }
    rasterizer := vk.PipelineRasterizationStateCreateInfo {
      sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      polygonMode = .FILL,
      cullMode    = {.BACK},
      frontFace   = desc.front_face,
    }
    info := vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &gpu.DEPTH_ONLY_RENDERING_INFO,
      stageCount          = stage_count,
      pStages             = raw_data(stages[:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
      pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
      pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
      pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
      layout              = self.depth_pipeline_layouts[kind],
    }
    vk.CreateGraphicsPipelines(
      gctx.device,
      0,
      1,
      &info,
      nil,
      &self.depth_pipelines[kind],
    ) or_return
  }
  return .SUCCESS
}

shutdown :: proc(self: ^System, gctx: ^gpu.GPUContext) {
  for kind in Kind {
    vk.DestroyPipeline(gctx.device, self.depth_pipelines[kind], nil)
    vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layouts[kind], nil)
    vk.DestroyPipeline(gctx.device, self.cull_pipelines[kind], nil)
    vk.DestroyPipelineLayout(gctx.device, self.cull_pipeline_layouts[kind], nil)
  }
  vk.DestroyDescriptorSetLayout(gctx.device, self.cull_descriptor_layout, nil)
  self.cull_descriptor_layout = 0
  self.cull_pipeline_layouts = {}
  self.cull_pipelines = {}
  self.depth_pipeline_layouts = {}
  self.depth_pipelines = {}
}

create_per_light_descriptor :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  node_buffer: vk.DescriptorBufferInfo,
  mesh_buffer: vk.DescriptorBufferInfo,
  draw_count: vk.DescriptorBufferInfo,
  draw_commands: vk.DescriptorBufferInfo,
) -> (
  vk.DescriptorSet,
  vk.Result,
) {
  return gpu.create_descriptor_set(
    gctx,
    &self.cull_descriptor_layout,
    {.STORAGE_BUFFER, node_buffer},
    {.STORAGE_BUFFER, mesh_buffer},
    {.STORAGE_BUFFER, draw_count},
    {.STORAGE_BUFFER, draw_commands},
  )
}

// cull writes the light's indirect draw list. `shape` is the light frustum
// planes for FRUSTUM lights or a Sphere for SPHERE lights.
cull :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  node_count: u32,
  shape: $Shape,
  draw_count_buffer: vk.Buffer,
  descriptor_set: vk.DescriptorSet,
) where Shape == Sphere || Shape == [6][4]f32 {
  kind := Kind.SPHERE when Shape == Sphere else Kind.FRUSTUM
  dispatch_x := (node_count + 63) / 64
  vk.CmdFillBuffer(
    command_buffer,
    draw_count_buffer,
    0,
    vk.DeviceSize(size_of(u32)),
    0,
  )
  gpu.buffer_barrier(
    command_buffer,
    draw_count_buffer,
    vk.DeviceSize(size_of(u32)),
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.cull_pipelines[kind],
    self.cull_pipeline_layouts[kind],
    descriptor_set,
  )
  push := CullPushConstants(Shape) {
    shape         = shape,
    node_count    = node_count,
    max_draws     = self.max_draws,
    include_flags = self.include_flags,
    exclude_flags = self.exclude_flags,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.cull_pipeline_layouts[kind],
    {.COMPUTE},
    0,
    size_of(push),
    &push,
  )
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}

record_frustum :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^bindless.TextureManager,
  scene: bindless.SceneBindings,
  view_projection: matrix[4, 4]f32,
  shadow_map: bindless.Texture2DHandle,
  draw_command: gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count: gpu.MutableBuffer(u32),
) {
  indirect_barriers(command_buffer, draw_command, draw_count)
  depth_texture := bindless.get_texture_2d(texture_manager, shadow_map)
  if depth_texture == nil do return
  push := FrustumDepthPushConstants {
    view_projection = view_projection,
  }
  draw_depth(
    self,
    .FRUSTUM,
    command_buffer,
    scene,
    depth_texture.image,
    gpu.create_depth_attachment(depth_texture, .CLEAR, .STORE),
    1,
    &push,
    draw_command.buffer,
    draw_count.buffer,
  )
}

record_sphere :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^bindless.TextureManager,
  scene: bindless.SceneBindings,
  projection: matrix[4, 4]f32,
  near, far: f32,
  position: [3]f32,
  shadow_map: bindless.TextureCubeHandle,
  draw_command: gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count: gpu.MutableBuffer(u32),
) {
  indirect_barriers(command_buffer, draw_command, draw_count)
  depth_cube := bindless.get_texture_cube(texture_manager, shadow_map)
  if depth_cube == nil do return
  push := SphereDepthPushConstants {
    projection     = projection,
    near_plane     = near,
    far_plane      = far,
    light_position = position,
  }
  // Flip clip-space X to match Vulkan cube-map sampling convention. Vulkan
  // disallows negative viewport width, so the flip lives in the projection
  // (paired with the CLOCKWISE front face to keep winding correct).
  push.projection[0, 0] = -push.projection[0, 0]
  push.projection[0, 1] = -push.projection[0, 1]
  push.projection[0, 2] = -push.projection[0, 2]
  push.projection[0, 3] = -push.projection[0, 3]
  draw_depth(
    self,
    .SPHERE,
    command_buffer,
    scene,
    depth_cube.image,
    gpu.create_cube_depth_attachment(depth_cube, .CLEAR, .STORE),
    6,
    &push,
    draw_command.buffer,
    draw_count.buffer,
  )
}

@(private = "file")
indirect_barriers :: proc(
  command_buffer: vk.CommandBuffer,
  draw_command: gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count: gpu.MutableBuffer(u32),
) {
  gpu.buffer_barrier(
    command_buffer,
    draw_command.buffer,
    vk.DeviceSize(draw_command.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    draw_count.buffer,
    vk.DeviceSize(draw_count.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
}

@(private = "file")
draw_depth :: proc(
  self: ^System,
  kind: Kind,
  command_buffer: vk.CommandBuffer,
  scene: bindless.SceneBindings,
  image: vk.Image,
  depth_attachment: vk.RenderingAttachmentInfo,
  layer_count: u32,
  push: rawptr,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
) {
  depth_attachment := depth_attachment
  extent := vk.Extent2D{self.shadow_map_size, self.shadow_map_size}
  gpu.image_discard_barrier(
    command_buffer,
    image,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH},
    layer_count = layer_count,
  )
  gpu.begin_depth_rendering(
    command_buffer,
    extent,
    &depth_attachment,
    layer_count = layer_count,
  )
  // The cube pass renders all faces through the geometry shader and keeps
  // the viewport unflipped.
  gpu.set_viewport_scissor(command_buffer, extent, flip_y = kind == .FRUSTUM)
  layout := self.depth_pipeline_layouts[kind]
  bindless.bind_scene(
    command_buffer,
    self.depth_pipelines[kind],
    layout,
    scene,
    SHADOW_SETS,
  )
  vk.CmdPushConstants(
    command_buffer,
    layout,
    KINDS[kind].depth_push_stages,
    0,
    KINDS[kind].depth_push_size,
    push,
  )
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    self.max_draws,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
  vk.CmdEndRendering(command_buffer)
  gpu.memory_barrier(
    command_buffer,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
  )
}
