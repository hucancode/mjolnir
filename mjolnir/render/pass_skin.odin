package render

import "rhi"

// Skinning: one dispatch a frame deforms every visible skinned node's mesh by its bone palette
// into the node's range of skinned vertices (Node.skin_vertex_base), which every vertex
// shader drawing the node reads in place of the mesh's: the G-buffer, forward and every shadow
// view share one skinning. A thread per skinned vertex finds its node in Table.SKIN_OWNERS.

@(private = "file")
SKIN_GROUP_SIZE :: 64

@(private)
skin_init :: proc(self: ^Renderer) -> bool {
  self.pipelines[.SKIN] = dev.compute_pipeline_create(
    &self.gpu,
    {shader_source("skin"), pipeline_layout(self, .SKIN)},
  ) or_return
  return true
}

// Before the frame's draws, which read what it writes.
@(private)
skin_declare :: proc(self: ^Renderer) {
  if self.skinned_vertex_count == 0 do return
  declare(self, "skinning", .COMPUTE, .SKIN, 0, as(skinned_use(self), .WRITE))
}

@(private)
skin_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  count := self.skinned_vertex_count
  pipeline_bind(self, cmd, self.pipelines[.SKIN], .SKIN, f, &count, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, (count + SKIN_GROUP_SIZE - 1) / SKIN_GROUP_SIZE, 1, 1)
}

// What every mesh draw reads that the frame writes: the skinned vertices, none without skinning.
@(private)
skinned_use :: proc(self: ^Renderer) -> GraphUse {
  return buffer_use(self.buffers[.SKINNED_VERTICES][0] if self.skinned_vertex_count > 0 else 0, .READ)
}
