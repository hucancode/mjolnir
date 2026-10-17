package render

import "rhi"

// Skinning: one dispatch a frame deforms every visible skinned node's mesh by its bone palette
// into the node's range of skinned vertices (Node.skin_vertex_base), which every vertex
// shader drawing the node reads in place of the mesh's: the G-buffer, forward and every shadow
// view share one skinning. A thread per skinned vertex finds its node in Table.SKIN_OWNERS.

@(private = "file")
SKIN_GROUP_SIZE :: 64

@(private)
skin_init :: proc(r: ^Renderer) -> bool {
  r.skin_pipeline = dev.compute_pipeline_create(
    &r.gpu,
    {{spirv = {comp = spirv("shader/vulkan/skinning/skin.spv")}, wgsl = wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/skin.wgsl"))}, pipeline_layout(r, .SKIN)},
  ) or_return
  return true
}

// Before the frame's draws, which read what it writes.
@(private)
skin_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  count := r.skinned_vertex_count
  if count == 0 do return
  barrier(r, cmd, .DRAW_TO_SKIN)
  dev.cmd_begin_compute(&r.gpu, cmd)
  push := SkinPush{count}
  pipeline_bind(r, cmd, r.skin_pipeline, .SKIN, f, &push, .NONE)
  dev.cmd_dispatch(&r.gpu, cmd, (count + SKIN_GROUP_SIZE - 1) / SKIN_GROUP_SIZE, 1, 1)
  dev.cmd_end_compute(&r.gpu, cmd)
  barrier(r, cmd, .SKIN_TO_DRAW)
}

@(private = "file")
SkinPush :: struct {
  vertex_count: u32,
}
