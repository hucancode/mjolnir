package render

import cont "../containers"
import "core:sync"
import "gpu"
import vk "vendor:vulkan"

// How a material is drawn: one pipeline (MATERIAL_SHADERS) and, per camera,
// one indirect draw list per type, drawn in this order. The types before
// FIRST_FORWARD_TYPE are opaque: drawn into the G-buffer, lit by the lighting
// pass, tested against the depth pyramid and drawn into shadow maps. The rest
// are drawn forward, alpha-blended over the lit image.
MaterialType :: enum u32 {
  PBR,
  TRANSPARENT,
  WIREFRAME,
  RANDOM_COLOR,
  // camera-facing billboard showing one cell of the albedo sprite sheet
  SPRITE,
}

@(private)
FIRST_FORWARD_TYPE :: MaterialType.TRANSPARENT
// bit t set for every G-buffer type t
@(private)
GBUFFER_TYPES :: u32(1) << u32(FIRST_FORWARD_TYPE) - 1

// Color names a builtin solid-color material in Renderer.builtin_materials.
Color :: enum {
  WHITE,
  BLACK,
  GRAY,
  RED,
  GREEN,
  BLUE,
  YELLOW,
  CYAN,
  MAGENTA,
}

// A material, stored as the shaders read it. A texture of 0 (NO_TEXTURE)
// leaves that texture out.
Material :: struct {
  albedo_index:             TextureHandle,
  metallic_roughness_index: TextureHandle,
  normal_index:             TextureHandle,
  emissive_index:           TextureHandle,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  _:                        u32,
  base_color_factor:        [4]f32,
  // .SPRITE: sheet size in cells and the cell shown, row-major
  frame_columns:            u32,
  frame_rows:               u32,
  frame_index:              u32,
  type:                     MaterialType,
}

// A pointer to a material in the table the next frame draws from: edit it in
// place. The pointer is valid until the next frame; edits from another
// thread than frame's happen between lock and unlock.
material :: proc(r: ^Renderer, h: MaterialHandle) -> (^Material, bool) #optional_ok {
  if !cont.slots_live(&r.material_slots, u32(h)) do return nil, false
  mark_dirty(r, .MATERIALS, Material, int(h))
  return &write_table(r, .MATERIALS, Material)[h], true
}

// Materials are app-lifetime but textures are level-lifetime: destroy a
// material that samples textures before teardown.
create_material :: proc(
  self: ^Renderer,
  type: MaterialType = .PBR,
  albedo_handle: TextureHandle = 0,
  metallic_roughness_handle: TextureHandle = 0,
  normal_handle: TextureHandle = 0,
  emissive_handle: TextureHandle = 0,
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
) -> (
  handle: MaterialHandle,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle = MaterialHandle(cont.slots_alloc(&self.material_slots) or_return)
  material(self, handle)^ = {
    type                     = type,
    albedo_index             = albedo_handle,
    metallic_roughness_index = metallic_roughness_handle,
    normal_index             = normal_handle,
    emissive_index           = emissive_handle,
    metallic_value           = metallic_value,
    roughness_value          = roughness_value,
    emissive_value           = emissive_value,
    base_color_factor        = base_color_factor,
    frame_columns            = max(frame_columns, 1),
    frame_rows               = max(frame_rows, 1),
  }
  return handle, true
}

// Solid-color PBR material from metallic/roughness/emissive scalars.
material_pbr :: proc(
  self: ^Renderer,
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    self,
    type              = .PBR,
    base_color_factor = base_color,
    metallic_value    = metallic,
    roughness_value   = roughness,
    emissive_value    = emissive,
  )
}

// material_wireframe creates a wireframe material of the given color.
material_wireframe :: proc(
  self: ^Renderer,
  base_color: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(self, type = .WIREFRAME, base_color_factor = base_color)
}

// material_transparent creates an alpha-blended material of the given color.
material_transparent :: proc(
  self: ^Renderer,
  base_color: [4]f32 = {1, 1, 1, 0.5},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(self, type = .TRANSPARENT, base_color_factor = base_color)
}

// Sprite-sheet material of `frame_columns` x `frame_rows` cells, tinted by
// `tint`. Attach it with the builtin QUAD_XY mesh; it always faces the camera.
material_sprite :: proc(
  self: ^Renderer,
  texture: TextureHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  tint: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    self,
    type = .SPRITE,
    albedo_handle = texture,
    base_color_factor = tint,
    frame_columns = frame_columns,
    frame_rows = frame_rows,
  )
}

// Show cell `frame` (row-major, wrapped to the sheet size) of a sprite
// material. Animate by calling this as time advances.
set_sprite_frame :: proc(self: ^Renderer, handle: MaterialHandle, frame: u32) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  m := material(self, handle) or_return
  m.frame_index = frame % (m.frame_columns * m.frame_rows)
  return true
}

// destroy_material frees the material slot; false if handle is not live.
destroy_material :: proc(self: ^Renderer, handle: MaterialHandle) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.material_slots, u32(handle)) or_return
  clear_entry(self, .MATERIALS, Material, u32(handle))
  return true
}

// A builtin primitive mesh drawn with a builtin color material.
primitive :: proc(
  self: ^Renderer,
  shape: Primitive = .CUBE,
  color: Color = .WHITE,
  cast_shadow := true,
) -> MeshAttachment {
  return {
    handle = self.builtin_meshes[shape],
    material = self.builtin_materials[color],
    cast_shadow = cast_shadow,
  }
}

@(private)
init_builtin_materials :: proc(self: ^Renderer) {
  colors := [Color][4]f32 {
    .WHITE = {1.0, 1.0, 1.0, 1.0},
    .BLACK = {0.0, 0.0, 0.0, 1.0},
    .GRAY = {0.3, 0.3, 0.3, 1.0},
    .RED = {1.0, 0.0, 0.0, 1.0},
    .GREEN = {0.0, 1.0, 0.0, 1.0},
    .BLUE = {0.0, 0.0, 1.0, 1.0},
    .YELLOW = {1.0, 1.0, 0.0, 1.0},
    .CYAN = {0.0, 1.0, 1.0, 1.0},
    .MAGENTA = {1.0, 0.0, 1.0, 1.0},
  }
  for color, i in colors {
    self.builtin_materials[i] = material_pbr(self, base_color = color) or_continue
  }
}

// Each MaterialType's pipeline is built against the targets of its pass (MATERIAL_PASS_TARGETS).
@(private)
MaterialPass :: enum {
  // writes the G-buffer and depth, lit by the lighting pass
  GBUFFER,
  // alpha-blends into the lit image, depth-tested without writing
  FORWARD,
}

// its outputs feed every mesh fragment shader
@(private = "file")
MESH_VERT :: #load("shader/gbuffer/vert.spv")

@(private)
MATERIAL_SHADERS := [MaterialType]struct {
  vert, frag:   []u8,
  polygon_mode: vk.PolygonMode,
  cull_mode:    vk.CullModeFlags,
} {
  .PBR          = {vert = MESH_VERT, frag = #load("shader/gbuffer/frag.spv"), cull_mode = {.BACK}},
  .TRANSPARENT  = {vert = MESH_VERT, frag = #load("shader/transparent/frag.spv"), cull_mode = {.BACK}},
  .WIREFRAME    = {vert = MESH_VERT, frag = #load("shader/wireframe/frag.spv"), polygon_mode = .LINE},
  .RANDOM_COLOR = {vert = MESH_VERT, frag = #load("shader/random_color/frag.spv"), cull_mode = {.BACK}},
  .SPRITE       = {vert = #load("shader/sprite/vert.spv"), frag = #load("shader/sprite/frag.spv")},
}

// `colors` and the camera depth, all loaded with `load`.
@(private)
MaterialPassTargets :: struct {
  colors: []AttachmentType,
  blend:  vk.PipelineColorBlendAttachmentState,
  depth:  vk.PipelineDepthStencilStateCreateInfo,
  load:   vk.AttachmentLoadOp,
}

@(private)
MATERIAL_PASS_TARGETS := [MaterialPass]MaterialPassTargets {
  .GBUFFER = {
    colors = {.NORMAL, .ALBEDO, .METALLIC_ROUGHNESS, .EMISSIVE},
    blend = gpu.BLEND_OVERRIDE,
    depth = gpu.READ_WRITE_DEPTH_STATE,
    load = .CLEAR,
  },
  .FORWARD = {
    colors = {.FINAL_IMAGE},
    blend = gpu.BLEND_ALPHA,
    depth = gpu.READ_ONLY_DEPTH_STATE,
    load = .LOAD,
  },
}

@(private)
MATERIAL_PASS_TYPES := [MaterialPass][2]MaterialType {
  .GBUFFER = {MaterialType(0), FIRST_FORWARD_TYPE},
  .FORWARD = {FIRST_FORWARD_TYPE, MaterialType(len(MaterialType))},
}

@(private)
material_pass_desc :: proc(pass: MaterialPass, desc: ^gpu.GraphicsPipelineDesc) {
  t := &MATERIAL_PASS_TARGETS[pass]
  formats := make([]vk.Format, len(t.colors), context.temp_allocator)
  blend := make([]vk.PipelineColorBlendAttachmentState, len(t.colors), context.temp_allocator)
  for a, i in t.colors {
    formats[i] = ATTACHMENTS[a].format
    blend[i] = t.blend
  }
  desc.color_formats = formats
  desc.blend = blend
  desc.depth = t.depth
  desc.depth_format = ATTACHMENTS[.DEPTH].format
}

@(private)
material_pipelines_init :: proc(r: ^Renderer) -> vk.Result {
  for pass in MaterialPass {
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      shaders := MATERIAL_SHADERS[type]
      // without fillModeNonSolid wireframe materials draw filled
      polygon_mode := shaders.polygon_mode
      if polygon_mode == .LINE && !r.gctx.fill_mode_non_solid do polygon_mode = .FILL
      pipeline := gpu.GraphicsPipelineDesc {
        vert = shaders.vert,
        frag = shaders.frag,
        vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
        topology = .TRIANGLE_LIST,
        polygon_mode = polygon_mode,
        cull_mode = shaders.cull_mode,
        layout = r.scene.layout,
      }
      material_pass_desc(pass, &pipeline)
      r.material_pipelines[type] = gpu.create_graphics_pipeline(&r.gctx, pipeline) or_return
    }
  }
  return .SUCCESS
}

// The forward pass draws particles first. A camera draws nothing until a cull has written its lists.
@(private)
material_pass_record :: proc(
  r: ^Renderer,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  pass: MaterialPass,
) {
  cmd := r.command_buffers[frame_index]
  t := &MATERIAL_PASS_TARGETS[pass]
  colors := make([]vk.RenderingAttachmentInfo, len(t.colors), context.temp_allocator)
  for a, i in t.colors do colors[i] = gpu.create_color_attachment(texture_image(r, cam.attachments[a][frame_index]).view, t.load)
  depth := texture_image(r, cam.attachments[.DEPTH][frame_index])
  gpu.begin_rendering(cmd, depth.extent, gpu.create_depth_attachment(depth.view, t.load), ..colors)
  push := cam_index
  push_constants(r, cmd, &push)
  if pass == .FORWARD do particles_draw(r, cmd)
  if r.gctx.frame_serial >= cam.ready_serial {
    bind_mesh_buffers(r, cmd)
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      vk.CmdBindPipeline(cmd, .GRAPHICS, r.material_pipelines[type])
      draw_lists_draw(&cam.draws, cmd, frame_index, u32(type))
    }
  }
  vk.CmdEndRendering(cmd)
}
