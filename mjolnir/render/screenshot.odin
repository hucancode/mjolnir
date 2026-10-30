package render

@(require) import "core:fmt"
import "core:log"
import "core:strings"
import "rhi"

// FRAME_DUMP is a directory (-define:FRAME_DUMP=dir): when set, every presented frame is
// written to it as 00000.png, 00001.png, ..., read back from the backbuffer without any window
// capture. The renderer waits for the GPU each frame to read it. Not on the web.
FRAME_DUMP :: #config(FRAME_DUMP, "")

// The backbuffer copied back for screenshot and FRAME_DUMP: one READBACK buffer of the
// backbuffer's size, recreated when it resizes.
@(private)
Capture :: struct {
  buffer:  rhi.Buffer,
  extent:  [2]u32,
  // screenshot's file (owned), and the frame_serial that copied it + 1, 0 before the copy
  path:    string,
  frame:   u64,
  // FRAME_DUMP: the frame_serial of the first dumped frame + 1, and of the last written + 1
  first:   u64,
  written: u64,
  failed:  bool,
}

// screenshot writes the next presented frame to `path` (copied) as a PNG, read back from the
// backbuffer without any window capture. The file appears a frame or two later, while the
// renderer runs a frame. A newer call replaces a pending one. False where the backend cannot
// copy the backbuffer, and on the web.
screenshot :: proc(self: ^Renderer, path: string) -> bool {
  when ODIN_OS == .JS do return false
  if !dev.caps(&self.gpu).backbuffer_copy do return false
  delete(self.capture.path)
  self.capture.path = strings.clone(path)
  self.capture.frame = 0
  return true
}

// Copies the finished backbuffer, last in `cmd`, when a screenshot or FRAME_DUMP wants it.
@(private)
capture_record :: proc(self: ^Renderer, cmd: rhi.CommandList) {
  c := &self.capture
  if c.failed || (FRAME_DUMP == "" && (c.path == "" || c.frame != 0)) do return
  if !dev.caps(&self.gpu).backbuffer_copy {
    log.warnf("FRAME_DUMP: this backend cannot copy the backbuffer")
    c.failed = true
    return
  }
  extent := dev.extent(&self.gpu)
  if extent != c.extent {
    dev.buffer_retire(&self.gpu, c.buffer)
    size := int(rhi.backbuffer_pitch(extent.x)) * int(extent.y)
    ok: bool
    c.buffer, ok = dev.buffer_create(&self.gpu, {size = size, usage = {.COPY_DST}, memory = .READBACK})
    if !ok {
      c.failed = true
      return
    }
    c.extent = extent
    when FRAME_DUMP != "" do if c.first == 0 do capture_mkdir(FRAME_DUMP)
  }
  dev.cmd_copy_backbuffer(&self.gpu, cmd, c.buffer)
  serial := dev.frame_serial(&self.gpu) + 1
  if c.path != "" do c.frame = serial
  if c.first == 0 do c.first = serial
}

// Writes the copied frame a screenshot or FRAME_DUMP waits for, once the GPU is done with it.
@(private)
capture_collect :: proc(self: ^Renderer) {
  c := &self.capture
  if c.buffer == 0 do return
  when FRAME_DUMP != "" {
    dev.wait_idle(&self.gpu)
  } else {
    if c.frame == 0 do return
  }
  width, height := int(c.extent.x), int(c.extent.y)
  pitch := int(rhi.backbuffer_pitch(c.extent.x))
  raw := make([]u8, pitch * height, context.temp_allocator)
  frame, ok := dev.buffer_read(&self.gpu, c.buffer, 0, raw)
  if !ok || frame == 0 do return
  bgra := dev.caps(&self.gpu).backbuffer_bgra
  rgb := make([]u8, width * height * 3, context.temp_allocator)
  for y in 0 ..< height {
    for x in 0 ..< width {
      src := raw[y * pitch + x * 4:][:3]
      dst := rgb[(y * width + x) * 3:][:3]
      dst[0], dst[1], dst[2] = src[2] if bgra else src[0], src[1], src[0] if bgra else src[2]
    }
  }
  if c.frame != 0 && frame >= c.frame {
    if !capture_write(c.path, width, height, rgb) do log.errorf("Cannot write screenshot %v", c.path)
    delete(c.path)
    c.path, c.frame = "", 0
  }
  when FRAME_DUMP != "" {
    if frame > c.written && frame >= c.first {
      name := fmt.tprintf("%s/%05d.png", FRAME_DUMP, frame - c.first)
      if !capture_write(name, width, height, rgb) do log.errorf("FRAME_DUMP: cannot write %v", name)
      c.written = frame
    }
  }
}

// Writes what is still waiting, at shutdown.
@(private)
capture_finish :: proc(self: ^Renderer) {
  c := &self.capture
  if c.buffer != 0 && (FRAME_DUMP != "" || c.frame != 0) {
    dev.wait_idle(&self.gpu)
    capture_collect(self)
  }
  dev.buffer_retire(&self.gpu, c.buffer)
  delete(c.path)
  c^ = {}
}
