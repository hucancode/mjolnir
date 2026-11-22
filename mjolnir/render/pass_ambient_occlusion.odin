package render

import "rhi"

// Ambient occlusion (GTAO): one compute dispatch per camera with an AmbientOcclusion
// (camera_effect) reads the G-buffer's depth and normals and writes the AMBIENT_OCCLUSION image whole,
// how much of the hemisphere above each pixel is open. The lighting pass scales the
// image-based light by it (shader/ambient_occlusion.slang, shader/lighting.slang). The image is a
// transient of the frame, written as a storage image: bindless at its storage view, or a group-3
// bind group per image (WebGPU).

@(private = "file")
AO_TILE :: 8

// Matches the push block of shader/ambient_occlusion.slang.
@(private = "file")
AmbientOcclusionPush :: struct {
  camera_index: u32,
  output_index: u32,
  radius:       f32,
  intensity:    f32,
  depth_index:  u32,
  normal_index: u32,
}

// WebGPU: group 3 of the dispatch, the image it writes.
@(private = "file")
AO_OUTPUT_LAYOUT :: GpuLayoutKey{count = 1, compute = true, kinds = {0 = .STORAGE_TEXTURE}, formats = {0 = .RGBA8_UNORM}}

@(private)
ambient_occlusion_init :: proc(self: ^Renderer) -> bool {
  output_layout: rhi.BindLayout
  when !BINDLESS do output_layout = gpu_layout(self, AO_OUTPUT_LAYOUT) or_return
  self.pipelines[.AMBIENT_OCCLUSION] = dev.compute_pipeline_create(
    &self.gpu,
    {
      shader_source("ambient_occlusion"),
      pipeline_layout(self, .AMBIENT_OCCLUSION, .AMBIENT_OCCLUSION, output_layout),
    },
  ) or_return
  return true
}

// Whether camera cam runs the ambient occlusion pass: the lighting pass reads its image then.
@(private)
ambient_occlusion_on :: proc(self: ^Renderer, cam: u32) -> bool {
  ao := camera_has(self, cam, AmbientOcclusion) or_return
  return ao.radius > 0 && ao.intensity > 0
}

// Camera g.arg's occlusion: its uses are the normals, the depth, the image it writes.
@(private)
ambient_occlusion_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, g: GraphPass) {
  cam := g.arg
  normal, depth, output := pass_texture(self, g, 0), pass_texture(self, g, 1), pass_texture(self, g, 2)
  group: rhi.BindGroup
  when !BINDLESS {
    resources := [1]rhi.BindResource{rhi.TextureView{output, 0}}
    ok: bool
    group, ok = cached_group(self, output, gpu_layout(self, AO_OUTPUT_LAYOUT) or_else 0, resources[:])
    if !ok do return
  }
  ao, _ := camera_has(self, cam, AmbientOcclusion)
  push := AmbientOcclusionPush {
    camera_index = cam,
    radius       = ao.radius,
    intensity    = ao.intensity,
    depth_index  = u32(depth),
    normal_index = u32(normal),
  }
  when BINDLESS do push.output_index = storage_view(self, output)
  pipeline_bind(self, cmd, self.pipelines[.AMBIENT_OCCLUSION], .AMBIENT_OCCLUSION, f, &push, .AMBIENT_OCCLUSION, normal, depth)
  if group != 0 do dev.cmd_bind_group(&self.gpu, cmd, 3, group)
  groups := (self.camera_targets[cam].extent + AO_TILE - 1) / AO_TILE
  dev.cmd_dispatch(&self.gpu, cmd, groups.x, groups.y, 1)
}
