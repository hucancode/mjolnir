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
skin_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  count := self.skinned_vertex_count
  if count == 0 do return
  barrier(self, cmd, .DRAW_TO_SKIN)
  dev.cmd_begin_compute(&self.gpu, cmd)
  vertex_count := count
  pipeline_bind(self, cmd, self.pipelines[.SKIN], .SKIN, f, &vertex_count, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, (count + SKIN_GROUP_SIZE - 1) / SKIN_GROUP_SIZE, 1, 1)
  dev.cmd_end_compute(&self.gpu, cmd)
  barrier(self, cmd, .SKIN_TO_DRAW)
}
