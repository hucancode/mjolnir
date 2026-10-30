package render

import "../containers"

// material_shader_create makes a material type past the built-in ones (Material.type), drawn
// by a compiled user shader whose fragment stage is its fs_main and, optionally, a vs_main that
// moves the mesh's vertices (procedural animation, defining CUSTOM_VERTEX before including
// material.slang); without one the vertex stage is render's. Its materials draw in the forward
// pass, after the built-in forward types, over the lit image: depth-tested, culled by `cull`,
// blended by `blend`, and writing depth unless `depth_write` is false (so nearer meshes hide
// farther ones drawn after them; a blended shader that discards nothing may want it off). They
// cast no shadow, are not occlusion-culled, are culled by the mesh's bounds (keep moved vertices
// near them) and see only the sun (View.sun_direction,
// sun_radiance). There is room for MAX_MATERIAL_SHADERS at once.
//
// Write the shader in Slang against shader/material.slang, which declares the scene buffers, the
// mesh vertex stage's outputs and the material's textures; load the compiled result with
// #load("name." + SHADER_EXT). It reads the material's params (Material.params), render's time
// and the image size there.
material_shader_create :: proc(
  self: ^Renderer,
  source: []u8,
  blend: BlendMode = .ALPHA,
  cull: CullMode = .BACK,
  depth_write := true,
) -> (
  type: MaterialType,
  ok: bool,
) #optional_ok {
  lock(self)
  slot := containers.slots_alloc(&self.slots[.MATERIAL_SHADERS]) or_return
  pipeline, created := material_pipeline_create(self, .FORWARD, {source = source, cull = cull, blend = blend, opaque = depth_write})
  if !created {
    containers.slots_free(&self.slots[.MATERIAL_SHADERS], slot)
    return {}, false
  }
  type = shader_type(slot)
  self.material_pipelines[.FORWARD][type] = pipeline
  return type, true
}

// material_shader_destroy frees a type from material_shader_create; its materials draw
// nothing until they get another.
material_shader_destroy :: proc(self: ^Renderer, type: MaterialType) {
  lock(self)
  if type < MaterialType(len(MaterialType)) || type >= MaterialType(DRAW_LISTS) do return
  if !containers.slots_free(&self.slots[.MATERIAL_SHADERS], u32(type) - len(MaterialType) + 1) do return
  dev.pipeline_retire(&self.gpu, self.material_pipelines[.FORWARD][type])
  self.material_pipelines[.FORWARD][type] = 0
}

// The material type of material shader slot `slot` (from 1).
@(private = "file")
shader_type :: #force_inline proc(slot: u32) -> MaterialType {
  return MaterialType(len(MaterialType) + slot - 1)
}

