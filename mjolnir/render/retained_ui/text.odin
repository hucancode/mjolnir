package retained_ui

import gpu "../../gpu"
import resources "../../resources"
import "core:log"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

push_text_quad :: proc(
  self: ^Manager,
  quad: fs.Quad,
  color: [4]u8,
  z: f32 = 0.0,
) {
  if self.text_vertex_count + 4 > TEXT_MAX_VERTICES ||
     self.text_index_count + 6 > TEXT_MAX_INDICES {
    log.warnf("Text vertex buffer full, dropping text")
    return
  }
  texture_id := self.text_atlas_handle.index
  self.text_vertices[self.text_vertex_count + 0] = {
    pos        = [2]f32{quad.x0, quad.y0},
    uv         = [2]f32{quad.s0, quad.t0},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  self.text_vertices[self.text_vertex_count + 1] = {
    pos        = [2]f32{quad.x1, quad.y0},
    uv         = [2]f32{quad.s1, quad.t0},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  self.text_vertices[self.text_vertex_count + 2] = {
    pos        = [2]f32{quad.x1, quad.y1},
    uv         = [2]f32{quad.s1, quad.t1},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  self.text_vertices[self.text_vertex_count + 3] = {
    pos        = [2]f32{quad.x0, quad.y1},
    uv         = [2]f32{quad.s0, quad.t1},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  vertex_base := u32(self.text_vertex_count)
  self.text_indices[self.text_index_count + 0] = vertex_base + 0
  self.text_indices[self.text_index_count + 1] = vertex_base + 1
  self.text_indices[self.text_index_count + 2] = vertex_base + 2
  self.text_indices[self.text_index_count + 3] = vertex_base + 2
  self.text_indices[self.text_index_count + 4] = vertex_base + 3
  self.text_indices[self.text_index_count + 5] = vertex_base + 0
  self.text_index_count += 6
  self.text_vertex_count += 4
}

draw_text_internal :: proc(
  self: ^Manager,
  text: string,
  x, y: f32,
  size: f32 = 16,
  color: [4]u8 = {255, 255, 255, 255},
  z: f32 = 0.0,
  align: TextAlign = .LEFT,
  clip_rect: [4]f32 = {0, 0, 0, 0},
  show_suffix: bool = false,
) {
  if len(text) == 0 {
    return
  }
  if raw_data(text) == nil {
    log.warnf("draw_text_internal: nil text pointer")
    return
  }
  fs.SetFont(&self.font_ctx, self.default_font)
  fs.SetSize(&self.font_ctx, size)
  fs.SetColor(&self.font_ctx, color)
  fs.SetAH(&self.font_ctx, .LEFT)
  fs.SetAV(&self.font_ctx, .BASELINE)

  bounds: [4]f32
  fs.TextBounds(&self.font_ctx, text, 0, 0, &bounds)
  text_width := bounds[2] - bounds[0]

  x_offset: f32 = 0
  if clip_rect.z > 0 {
    if text_width <= clip_rect.z {
      switch align {
      case .LEFT:
        x_offset = 0
      case .CENTER:
        x_offset = (clip_rect.z - text_width) * 0.5
      case .RIGHT:
        x_offset = clip_rect.z - text_width
      }
    } else {
      if show_suffix {
        x_offset = clip_rect.z - text_width
      } else {
        x_offset = 0
      }
    }
  } else {
    switch align {
    case .LEFT:
      x_offset = 0
    case .CENTER:
      x_offset = -text_width * 0.5
    case .RIGHT:
      x_offset = -text_width
    }
  }

  text_x := x + x_offset
  clip_enabled := clip_rect.z > 0
  clip_left := clip_rect.x
  clip_right := clip_rect.x + clip_rect.z
  clip_top := clip_rect.y
  clip_bottom := clip_rect.y + clip_rect.w

  iter := fs.TextIterInit(&self.font_ctx, text_x, y, text)
  quad: fs.Quad
  for fs.TextIterNext(&self.font_ctx, &iter, &quad) {
    if clip_enabled {
      if quad.x1 < clip_left ||
         quad.x0 > clip_right ||
         quad.y1 < clip_top ||
         quad.y0 > clip_bottom {
        continue
      }
      clipped_quad := quad
      if clipped_quad.x0 < clip_left {
        uv_adjust :=
          (clip_left - clipped_quad.x0) / (clipped_quad.x1 - clipped_quad.x0)
        clipped_quad.s0 =
          clipped_quad.s0 + (clipped_quad.s1 - clipped_quad.s0) * uv_adjust
        clipped_quad.x0 = clip_left
      }
      if clipped_quad.x1 > clip_right {
        uv_adjust :=
          (clipped_quad.x1 - clip_right) / (clipped_quad.x1 - clipped_quad.x0)
        clipped_quad.s1 =
          clipped_quad.s1 - (clipped_quad.s1 - clipped_quad.s0) * uv_adjust
        clipped_quad.x1 = clip_right
      }
      if clipped_quad.y0 < clip_top {
        uv_adjust :=
          (clip_top - clipped_quad.y0) / (clipped_quad.y1 - clipped_quad.y0)
        clipped_quad.t0 =
          clipped_quad.t0 + (clipped_quad.t1 - clipped_quad.t0) * uv_adjust
        clipped_quad.y0 = clip_top
      }
      if clipped_quad.y1 > clip_bottom {
        uv_adjust :=
          (clipped_quad.y1 - clip_bottom) / (clipped_quad.y1 - clipped_quad.y0)
        clipped_quad.t1 =
          clipped_quad.t1 - (clipped_quad.t1 - clipped_quad.t0) * uv_adjust
        clipped_quad.y1 = clip_bottom
      }
      push_text_quad(self, clipped_quad, color, z)
    } else {
      push_text_quad(self, quad, color, z)
    }
  }
}

flush_text :: proc(
  self: ^Manager,
  cmd_buf: vk.CommandBuffer,
  rm: ^resources.Manager,
) -> vk.Result {
  new_vertex_count :=
    self.text_vertex_count - self.text_cumulative_vertex_count
  new_index_count := self.text_index_count - self.text_cumulative_index_count
  if new_vertex_count == 0 && new_index_count == 0 {
    return .SUCCESS
  }
  gpu.write(
    &self.text_vertex_buffer,
    self.text_vertices[:self.text_vertex_count],
  ) or_return
  gpu.write(
    &self.text_index_buffer,
    self.text_indices[:self.text_index_count],
  ) or_return
  gpu.bind_graphics_pipeline(
    cmd_buf,
    self.pipeline,
    self.pipeline_layout,
    self.projection_descriptor_set,
    rm.textures_descriptor_set,
  )
  gpu.set_viewport_scissor(cmd_buf, self.frame_width, self.frame_height)
  offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    cmd_buf,
    0,
    1,
    &self.text_vertex_buffer.buffer,
    raw_data(offsets[:]),
  )
  vk.CmdBindIndexBuffer(cmd_buf, self.text_index_buffer.buffer, 0, .UINT32)
  first_index := self.text_cumulative_index_count
  vk.CmdDrawIndexed(cmd_buf, new_index_count, 1, first_index, 0, 0)
  self.text_cumulative_vertex_count = self.text_vertex_count
  self.text_cumulative_index_count = self.text_index_count

  return .SUCCESS
}
