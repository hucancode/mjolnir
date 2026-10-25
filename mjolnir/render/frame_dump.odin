package render

import "core:fmt"
import "core:log"
import "rhi"

// FRAME_DUMP is a directory (-define:FRAME_DUMP=dir): when set, every presented frame is
// written to it as 00000.png, 00001.png, ..., read back from the backbuffer without any window
// capture. Only where the backend can copy the backbuffer (Vulkan).
FRAME_DUMP :: #config(FRAME_DUMP, "")

// The frames copied but not yet written: one per frame in flight, written once the frame slot
// is waited on again.
@(private)
FrameDump :: struct {
  buffers: [FRAMES_IN_FLIGHT]rhi.Buffer,
  // the number of the frame a slot's buffer holds, 0 when none
  pending: [FRAMES_IN_FLIGHT]int,
  extent:  [2]u32,
  count:   int,
  failed:  bool,
}

@(private)
dump_pitch :: proc(width: u32) -> int {
  return (int(width) * 4 + rhi.BACKBUFFER_PITCH - 1) / rhi.BACKBUFFER_PITCH * rhi.BACKBUFFER_PITCH
}

// Records the copy of the finished backbuffer into slot f's buffer, last in `cmd`.
@(private)
dump_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  when FRAME_DUMP != "" {
    d := &self.dump
    if d.failed do return
    if !dev.caps(&self.gpu).backbuffer_copy {
      log.warnf("FRAME_DUMP: this backend cannot copy the backbuffer")
      d.failed = true
      return
    }
    extent := dev.extent(&self.gpu)
    if extent != d.extent {
      dump_release(self)
      d.extent = extent
      dump_mkdir(FRAME_DUMP)
    }
    if d.buffers[f] == 0 {
      size := dump_pitch(extent.x) * int(extent.y)
      ok: bool
      d.buffers[f], ok = dev.buffer_create(&self.gpu, {size = size, usage = {.COPY_DST}, memory = .READBACK})
      if !ok {
        d.failed = true
        return
      }
    }
    dev.cmd_copy_backbuffer(&self.gpu, cmd, d.buffers[f])
    d.count += 1
    d.pending[f] = d.count
  }
}

// Writes slot f's frame once the GPU is done with it.
@(private)
dump_collect :: proc(self: ^Renderer, f: u32) {
  when FRAME_DUMP != "" {
    d := &self.dump
    if d.pending[f] == 0 do return
    width, height := int(d.extent.x), int(d.extent.y)
    pitch := dump_pitch(d.extent.x)
    raw := make([]u8, pitch * height, context.temp_allocator)
    if !dev.buffer_read(&self.gpu, d.buffers[f], 0, raw) do return
    bgra := dev.caps(&self.gpu).backbuffer_bgra
    rgb := make([]u8, width * height * 3, context.temp_allocator)
    for y in 0 ..< height {
      for x in 0 ..< width {
        src := raw[y * pitch + x * 4:][:3]
        dst := rgb[(y * width + x) * 3:][:3]
        dst[0], dst[1], dst[2] = src[2] if bgra else src[0], src[1], src[0] if bgra else src[2]
      }
    }
    name := fmt.tprintf("%s/%05d.png", FRAME_DUMP, d.pending[f] - 1)
    if !dump_write(name, width, height, rgb) do log.errorf("FRAME_DUMP: cannot write %v", name)
    d.pending[f] = 0
  }
}

// Waits for the GPU and writes every frame still pending, at shutdown.
@(private)
dump_finish :: proc(self: ^Renderer) {
  when FRAME_DUMP != "" {
    dev.wait_idle(&self.gpu)
    // oldest first
    for _ in 0 ..< FRAMES_IN_FLIGHT {
      oldest, at := max(int), -1
      for p, i in self.dump.pending do if p != 0 && p < oldest do oldest, at = p, i
      if at < 0 do break
      dump_collect(self, u32(at))
    }
    dump_release(self)
  }
}

@(private)
dump_release :: proc(self: ^Renderer) {
  when FRAME_DUMP != "" {
    for f in 0 ..< FRAMES_IN_FLIGHT {
      if self.dump.pending[f] != 0 do dump_collect(self, u32(f))
      dev.buffer_retire(&self.gpu, self.dump.buffers[f])
      self.dump.buffers[f] = 0
    }
  }
}
