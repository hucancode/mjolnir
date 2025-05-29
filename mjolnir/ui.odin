package mjolnir

import intr "base:intrinsics"
import "core:fmt"
import linalg "core:math/linalg"
import mu "vendor:microui"
import vk "vendor:vulkan"

UI_MAX_QUAD :: 1000
UI_MAX_VERTICES :: UI_MAX_QUAD * 4
UI_MAX_INDICES :: UI_MAX_QUAD * 6
// --- UI State ---
UIRenderer :: struct {
  ctx:           mu.Context,
  pipeline:      Pipeline2D,
  atlas:         Texture,
  proj_buffer:   DataBuffer,
  vertex_buffer: DataBuffer,
  index_buffer:  DataBuffer,
  vertex_count:  u32,
  index_count:   u32,
  vertices:      [UI_MAX_VERTICES]Vertex2D,
  indices:       [UI_MAX_INDICES]u32,
  frame_width:   u32,
  frame_height:  u32,
}

Vertex2D :: struct {
  pos:   [2]f32,
  uv:    [2]f32,
  color: [4]u8,
}

ui_init :: proc(
  ui: ^UIRenderer,
  engine: ^Engine,
  color_format: vk.Format,
  width: u32,
  height: u32,
) -> vk.Result {
  mu.init(&ui.ctx)
  ui.ctx.text_width = mu.default_atlas_text_width
  ui.ctx.text_height = mu.default_atlas_text_height
  ui.frame_width = width
  ui.frame_height = height
  fmt.printfln("init UI pipeline...")
  pipeline2d_init(&ui.pipeline, color_format) or_return
  fmt.printfln("init UI texture...")
  _, texture := create_texture_from_pixels(
    engine,
    mu.default_atlas_alpha[:],
    mu.DEFAULT_ATLAS_WIDTH,
    mu.DEFAULT_ATLAS_HEIGHT,
    1,
    .R8_UNORM,
  ) or_return
  ui.atlas = texture^
  fmt.printfln("init UI vertex buffer...")
  ui.vertex_buffer = create_host_visible_buffer(
    size_of(Vertex2D) * vk.DeviceSize(UI_MAX_VERTICES),
    {.VERTEX_BUFFER},
  ) or_return
  fmt.printfln("init UI indices buffer...")
  ui.index_buffer = create_host_visible_buffer(
    size_of(u32) * vk.DeviceSize(UI_MAX_INDICES),
    {.INDEX_BUFFER},
  ) or_return
  // Write atlas texture and sampler to texture_descriptor_set
  image_info := vk.DescriptorImageInfo {
    sampler     = ui.atlas.sampler,
    imageView   = ui.atlas.buffer.view,
    imageLayout = .SHADER_READ_ONLY_OPTIMAL,
  }
  ortho := linalg.matrix_ortho3d(0, f32(width), f32(height), 0, -1, 1)
  fmt.printfln("init UI proj buffer...")
  ui.proj_buffer = create_host_visible_buffer(
    size_of(linalg.Matrix4f32),
    {.UNIFORM_BUFFER},
  ) or_return
  data_buffer_write(
    &ui.proj_buffer,
    raw_data(&ortho),
    size_of(linalg.Matrix4f32),
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = ui.proj_buffer.buffer,
    range  = size_of(linalg.Matrix4f32),
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = ui.pipeline.projection_descriptor_set,
      dstBinding = 0,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType = .UNIFORM_BUFFER,
      pBufferInfo = &buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = ui.pipeline.texture_descriptor_set,
      dstBinding = 0,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      pImageInfo = &image_info,
    },
  }
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  fmt.printfln("done init UI")
  return .SUCCESS
}

ui_render :: proc(ui: ^UIRenderer, cmd_buf: vk.CommandBuffer) {
  command_backing: ^mu.Command
  for variant in mu.next_command_iterator(&ui.ctx, &command_backing) {
    // fmt.printfln("executing UI command", variant)
    switch cmd in variant {
    case ^mu.Command_Text:
      ui_draw_text(ui, cmd_buf, cmd.str, cmd.pos, cmd.color)
    case ^mu.Command_Rect:
      ui_draw_rect(ui, cmd_buf, cmd.rect, cmd.color)
    case ^mu.Command_Icon:
      ui_draw_icon(ui, cmd_buf, cmd.id, cmd.rect, cmd.color)
    case ^mu.Command_Clip:
      ui_set_clip_rect(ui, cmd_buf, cmd.rect)
    case ^mu.Command_Jump:
      unreachable()
    }
  }
  ui_flush(ui, cmd_buf)
}

ui_flush :: proc(ui: ^UIRenderer, cmd_buf: vk.CommandBuffer) -> vk.Result {
  if ui.vertex_count == 0 && ui.index_count == 0 {
    return .SUCCESS
  }
  defer {
    ui.vertex_count = 0
    ui.index_count = 0
  }
  // fmt.printfln("going to write vertex/index buffer...", ui.vertex_buffer)
  data_buffer_write(
    &ui.vertex_buffer,
    raw_data(ui.vertices[:]),
    vk.DeviceSize(size_of(Vertex2D) * ui.vertex_count),
  ) or_return
  data_buffer_write(
    &ui.index_buffer,
    raw_data(ui.indices[:]),
    vk.DeviceSize(size_of(u32) * ui.index_count),
  ) or_return
  vk.CmdBindPipeline(cmd_buf, .GRAPHICS, ui.pipeline.pipeline)
  descriptor_sets := [?]vk.DescriptorSet {
    ui.pipeline.projection_descriptor_set,
    ui.pipeline.texture_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    cmd_buf,
    .GRAPHICS,
    ui.pipeline.pipeline_layout,
    0,
    2,
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(ui.frame_height),
    width    = f32(ui.frame_width),
    height   = -f32(ui.frame_height),
    minDepth = 0,
    maxDepth = 1,
  }
  vk.CmdSetViewport(cmd_buf, 0, 1, &viewport)
  offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    cmd_buf,
    0,
    1,
    &ui.vertex_buffer.buffer,
    raw_data(offsets[:]),
  )
  vk.CmdBindIndexBuffer(cmd_buf, ui.index_buffer.buffer, 0, .UINT32)
  vk.CmdDrawIndexed(cmd_buf, ui.index_count, 1, 0, 0, 0)
  return .SUCCESS
}

ui_push_quad :: proc(
  ui: ^UIRenderer,
  cmd_buf: vk.CommandBuffer,
  dst, src: mu.Rect,
  color: mu.Color,
) {
  if (ui.vertex_count >= UI_MAX_VERTICES || ui.index_count >= UI_MAX_INDICES) {
    ui_flush(ui, cmd_buf)
  }
  x, y, w, h :=
    f32(src.x) /
    mu.DEFAULT_ATLAS_WIDTH,
    f32(src.y) /
    mu.DEFAULT_ATLAS_HEIGHT,
    f32(src.w) /
    mu.DEFAULT_ATLAS_WIDTH,
    f32(src.h) /
    mu.DEFAULT_ATLAS_HEIGHT
  dx, dy, dw, dh := f32(dst.x), f32(dst.y), f32(dst.w), f32(dst.h)
  ui.vertices[ui.vertex_count + 0] = {
    pos   = [2]f32{dx, dy},
    uv    = [2]f32{x, y},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  ui.vertices[ui.vertex_count + 1] = {
    pos   = [2]f32{dx + dw, dy},
    uv    = [2]f32{x + w, y},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  ui.vertices[ui.vertex_count + 2] = {
    pos   = [2]f32{dx + dw, dy + dh},
    uv    = [2]f32{x + w, y + h},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  ui.vertices[ui.vertex_count + 3] = {
    pos   = [2]f32{dx, dy + dh},
    uv    = [2]f32{x, y + h},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  ui.indices[ui.index_count + 0] = ui.vertex_count + 0
  ui.indices[ui.index_count + 1] = ui.vertex_count + 1
  ui.indices[ui.index_count + 2] = ui.vertex_count + 2
  ui.indices[ui.index_count + 3] = ui.vertex_count + 2
  ui.indices[ui.index_count + 4] = ui.vertex_count + 3
  ui.indices[ui.index_count + 5] = ui.vertex_count + 0
  ui.index_count += 6
  ui.vertex_count += 4
}

ui_draw_rect :: proc(
  ui: ^UIRenderer,
  cmd_buf: vk.CommandBuffer,
  rect: mu.Rect,
  color: mu.Color,
) {
  ui_push_quad(
    ui,
    cmd_buf,
    rect,
    mu.default_atlas[mu.DEFAULT_ATLAS_WHITE],
    color,
  )
}

ui_draw_text :: proc(
  ui: ^UIRenderer,
  cmd_buf: vk.CommandBuffer,
  text: string,
  pos: mu.Vec2,
  color: mu.Color,
) {
  dst := mu.Rect{pos.x, pos.y, 0, 0}
  for ch in text {
    if ch & 0xc0 != 0x80 {
      r := min(int(ch), 127)
      src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
      dst.w = src.w
      dst.h = src.h
      ui_push_quad(ui, cmd_buf, dst, src, color)
      dst.x += dst.w
    }
  }
}

ui_draw_icon :: proc(
  ui: ^UIRenderer,
  cmd_buf: vk.CommandBuffer,
  id: mu.Icon,
  rect: mu.Rect,
  color: mu.Color,
) {
  src := mu.default_atlas[id]
  x := rect.x + (rect.w - src.w) / 2
  y := rect.y + (rect.h - src.h) / 2
  ui_push_quad(ui, cmd_buf, {x, y, src.w, src.h}, src, color)
}

ui_set_clip_rect :: proc(
  ui: ^UIRenderer,
  cmd_buf: vk.CommandBuffer,
  rect: mu.Rect,
) {
  ui_flush(ui, cmd_buf)
  x := min(rect.x, i32(ui.frame_width))
  y := min(rect.y, i32(ui.frame_height))
  w := u32(min(rect.w, i32(ui.frame_width) - x))
  h := u32(min(rect.h, i32(ui.frame_height) - y))
  scissor := vk.Rect2D {
    offset = {x, y},
    extent = {w, h},
  }
  vk.CmdSetScissor(cmd_buf, 0, 1, &scissor)
}
