#+private
package render

import geom "../geometry"
import "gpu"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADOW_DEPTH_VERT :: #load("shader/shadow/vert.spv")

// Nodes drawn into shadow maps: visible casters that are not drawn by a
// forward pipeline.
SHADOW_INCLUDE :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
SHADOW_EXCLUDE :: NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_SPRITE}

ShadowCullPushConstants :: struct {
  planes:        [6][4]f32,
  node_count:    u32,
  max_draws:     u32,
  include_flags: u32,
  exclude_flags: u32,
}

ShadowDepthPushConstants :: struct {
  view_projection: matrix[4, 4]f32,
}

// Depth passes bind every mesh set except the camera.
SHADOW_SETS :: MESH_SETS - {.CAMERA}

ShadowSystem :: struct {
  cull_descriptor_layout: vk.DescriptorSetLayout,
  cull_pipeline_layout:   vk.PipelineLayout,
  cull_pipeline:          vk.Pipeline,
  depth_pipeline_layout:  vk.PipelineLayout,
  depth_pipeline:         vk.Pipeline,
}

// Per-frame shadow math for one light, shared by the depth pass and the
// lighting pass. A point light uses `projection` for every cube face (the
// face views come from point_face_view) and leaves `view_projection` unset.
ShadowFrameInfo :: struct {
  view_projection: matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  near, far:       f32,
}

shadow_safe_normalize :: proc(v: [3]f32, fallback: [3]f32) -> [3]f32 {
  len_sq := linalg.dot(v, v)
  if len_sq < 1e-6 do return fallback
  return linalg.normalize(v)
}

shadow_make_light_view :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  forward := shadow_safe_normalize(direction, {0, -1, 0})
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(forward, up)) > 0.95 {
    up = {0, 0, 1}
  }
  target := position + forward
  return linalg.matrix4_look_at(position, target, up)
}

shadow_matrices_spot :: proc(
  position, direction: [3]f32,
  radius, angle_outer: f32,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius)
  view = shadow_make_light_view(position, direction)
  fovy := max(angle_outer * 2.0, 0.001)
  projection = geom.make_perspective_matrix(fovy, 1.0, near, far)
  return
}

shadow_matrices_directional :: proc(
  position, direction: [3]f32,
  radius: f32,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius * 2.0)
  camera_pos := position - direction * radius
  view = shadow_make_light_view(camera_pos, direction)
  half_extent := max(radius, 0.5)
  projection = geom.make_ortho_matrix(
    -half_extent,
    half_extent,
    -half_extent,
    half_extent,
    near,
    far,
  )
  return
}

shadow_projection_point :: proc(
  radius: f32,
) -> (
  projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, radius)
  projection = geom.make_perspective_matrix(
    f32(math.PI * 0.5),
    1.0,
    near,
    far,
  )
  return
}

// View from `position` through cube face `face` (+X, -X, +Y, -Y, +Z, -Z),
// oriented so that, with an unflipped viewport, the rendered image lands
// where Vulkan's cube sampling reads it.
point_face_view :: proc(position: [3]f32, face: int) -> matrix[4, 4]f32 {
  @(static, rodata)
  FACES := [6][2][3]f32 {
    {{1, 0, 0}, {0, -1, 0}},
    {{-1, 0, 0}, {0, -1, 0}},
    {{0, 1, 0}, {0, 0, 1}},
    {{0, -1, 0}, {0, 0, -1}},
    {{0, 0, 1}, {0, -1, 0}},
    {{0, 0, -1}, {0, -1, 0}},
  }
  return linalg.matrix4_look_at(position, position + FACES[face][0], FACES[face][1])
}

shadow_init :: proc(r: ^Manager) -> (ret: vk.Result) {
  self := &r.internal.shadow
  gctx := &r.gctx
  defer if ret != .SUCCESS do shadow_shutdown(self, gctx)
  self.cull_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}}, // nodes
    {.STORAGE_BUFFER, {.COMPUTE}}, // meshes
    {.STORAGE_BUFFER, {.COMPUTE}}, // draw_count
    {.STORAGE_BUFFER, {.COMPUTE}}, // draw_commands
  ) or_return
  self.cull_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.COMPUTE}, size = size_of(ShadowCullPushConstants)},
    self.cull_descriptor_layout,
  ) or_return
  self.cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    #load("shader/shadow/cull.spv"),
    self.cull_pipeline_layout,
  ) or_return
  self.depth_pipeline_layout = create_scene_pipeline_layout(
    r,
    SHADOW_SETS,
    {stageFlags = {.VERTEX}, size = size_of(ShadowDepthPushConstants)},
  ) or_return
  // Cube faces are mirror images of an ordinary view, so the front face is
  // set per draw.
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .FRONT_FACE}
  self.depth_pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = SHADOW_DEPTH_VERT,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = POSITION_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      raster = {polygonMode = .FILL, cullMode = {.BACK}},
      depth = gpu.READ_WRITE_DEPTH_STATE,
      depth_format = .D32_SFLOAT,
      dynamic_states = dynamic_states[:],
      layout = self.depth_pipeline_layout,
    },
  ) or_return
  return .SUCCESS
}

shadow_shutdown :: proc(self: ^ShadowSystem, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.cull_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.cull_descriptor_layout, nil)
  self^ = {}
}

shadow_create_per_light_descriptor :: proc(
  self: ^ShadowSystem,
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

// Render one light's shadow map for this frame. A spot or directional light
// is one view; a point light is six, one per cube face. Each view culls the
// casters inside its frustum into the light's draw list and draws their
// depth; cube faces take turns on the one list.
shadow_record :: proc(r: ^Manager, frame_index: u32, fl: ^FrameLight) {
  sm := fl.shadow_map
  if sm == nil do return
  cmd := r.internal.command_buffers[frame_index]
  depth :=
    get_texture_cube(&r.texture_manager, sm.textures[frame_index]) if sm.cube else get_texture_2d(&r.texture_manager, sm.textures[frame_index])
  if depth == nil do return
  gpu.image_discard_barrier(
    cmd,
    depth.image,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH},
    layer_count = 6 if sm.cube else 1,
  )
  if sm.cube {
    for face_view, face in depth.face_views {
      if face > 0 {
        // the previous face's draw has read the list this cull rewrites
        gpu.memory_barrier(
          cmd,
          {.INDIRECT_COMMAND_READ},
          {.TRANSFER_WRITE, .SHADER_WRITE},
          {.DRAW_INDIRECT},
          {.TRANSFER, .COMPUTE_SHADER},
        )
      }
      view_projection := fl.info.projection * point_face_view(fl.params.position, face)
      shadow_draw_view(r, frame_index, sm, view_projection, face_view, cube_face = true)
    }
  } else {
    shadow_draw_view(r, frame_index, sm, fl.info.view_projection, depth.view, cube_face = false)
  }
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
  )
}

// Cull the casters inside `view_projection` into the shadow map's draw list,
// then draw their depth into `target`.
@(private = "file")
shadow_draw_view :: proc(
  r: ^Manager,
  frame_index: u32,
  sm: ^ShadowMap,
  view_projection: matrix[4, 4]f32,
  target: vk.ImageView,
  cube_face: bool,
) {
  self := &r.internal.shadow
  cmd := r.internal.command_buffers[frame_index]
  commands := &sm.draws.commands[frame_index]
  count := &sm.draws.count[frame_index]
  shadow_cull(r, cmd, geom.make_frustum(view_projection).planes, count.buffer, sm.descriptor_sets[frame_index])
  indirect_barrier(cmd, commands, count)
  extent := vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
  gpu.begin_rendering(cmd, extent, gpu.create_depth_attachment(target))
  // 2D maps flip Y like the cameras; cube faces stay unflipped to match cube
  // sampling, which mirrors them, so their winding turns clockwise.
  gpu.set_viewport_scissor(cmd, extent, flip_y = !cube_face)
  vk.CmdSetFrontFace(cmd, .CLOCKWISE if cube_face else .COUNTER_CLOCKWISE)
  bind_scene(r, cmd, frame_index, self.depth_pipeline, self.depth_pipeline_layout, SHADOW_SETS)
  push := ShadowDepthPushConstants{view_projection}
  vk.CmdPushConstants(cmd, self.depth_pipeline_layout, {.VERTEX}, 0, size_of(push), &push)
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    commands.buffer,
    0,
    count.buffer,
    0,
    MAX_NODES_IN_SCENE,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
  vk.CmdEndRendering(cmd)
}

@(private = "file")
shadow_cull :: proc(
  r: ^Manager,
  command_buffer: vk.CommandBuffer,
  planes: [6][4]f32,
  draw_count_buffer: vk.Buffer,
  descriptor_set: vk.DescriptorSet,
) {
  self := &r.internal.shadow
  vk.CmdFillBuffer(command_buffer, draw_count_buffer, 0, vk.DeviceSize(size_of(u32)), 0)
  gpu.buffer_barrier(
    command_buffer,
    draw_count_buffer,
    vk.DeviceSize(size_of(u32)),
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_pipeline(
    command_buffer,
    .COMPUTE,
    self.cull_pipeline,
    self.cull_pipeline_layout,
    descriptor_set,
  )
  push := ShadowCullPushConstants {
    planes        = planes,
    node_count    = r.node_count,
    max_draws     = MAX_NODES_IN_SCENE,
    include_flags = transmute(u32)SHADOW_INCLUDE,
    exclude_flags = transmute(u32)SHADOW_EXCLUDE,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.cull_pipeline_layout,
    {.COMPUTE},
    0,
    size_of(push),
    &push,
  )
  vk.CmdDispatch(command_buffer, (r.node_count + 63) / 64, 1, 1)
}
