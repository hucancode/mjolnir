package render

import "../containers"
import "core:log"
import "core:math"

// SpriteFrame is one picture of a sprite: the texture coordinates its quad's top-left,
// top-right, bottom-right and bottom-left corners show (an atlas entry stored turned is its
// corners turned), and the quad's centre from the node and its size, both times the node's scale
// (x right, y up). Trimmed atlas frames keep their place with offset.
SpriteFrame :: struct {
  uv:     [4][2]f32,
  offset: [2]f32,
  size:   [2]f32,
}
#assert(size_of(SpriteFrame) == 48)

// SpriteFramesHandle is a sprite frame set (sprite_frames_create), the frames of a .SPRITE
// material (Material.sprite_frames).
SpriteFramesHandle :: distinct u32

// The first frame of a live set.
@(private = "file")
sprite_frames_first :: proc(self: ^Renderer, frames: SpriteFramesHandle) -> (first: u32, ok: bool) {
  first = u32(frames) - 1
  return first, frames != 0 && containers.ranges_size(&self.sprite_frame_ranges, first) > 0
}

// sprite_frames_create stores a frame set, e.g. the frames of one texture atlas page (a
// material draws from one texture, so a many-page atlas is a set and a material per page). It
// lives until sprite_frames_destroy or teardown. false for no frames.
sprite_frames_create :: proc(self: ^Renderer, frames: []SpriteFrame) -> (handle: SpriteFramesHandle, ok: bool) #optional_ok {
  lock(self)
  if len(frames) == 0 do return 0, false
  first, has_room := ranges_alloc_growing(self, &self.sprite_frame_ranges, .SPRITE_FRAMES, u32(len(frames)))
  if !has_room {
    log.warnf("No room for %d sprite frames", len(frames))
    return 0, false
  }
  copy(write_table(self, .SPRITE_FRAMES, SpriteFrame)[first:], frames)
  mark_dirty(self, .SPRITE_FRAMES, int(first), len(frames))
  return SpriteFramesHandle(first + 1), true
}

// sprite_frames_destroy frees the set; materials still naming it draw nothing sensible until
// given another.
sprite_frames_destroy :: proc(self: ^Renderer, frames: SpriteFramesHandle) {
  lock(self)
  first, live := sprite_frames_first(self, frames)
  if !live do return
  containers.ranges_free(&self.sprite_frame_ranges, first)
}

// sprite_frames_grid returns the frames of a sheet of columns x rows equal cells, row-major
// from the top-left, each `size` (set the node's scale for the cell's aspect).
sprite_frames_grid :: proc(columns, rows: u32, size: [2]f32 = {1, 1}, allocator := context.temp_allocator) -> []SpriteFrame {
  columns, rows := max(columns, 1), max(rows, 1)
  frames := make([]SpriteFrame, columns * rows, allocator)
  cell := 1 / [2]f32{f32(columns), f32(rows)}
  for &f, i in frames {
    p0 := [2]f32{f32(u32(i) % columns), f32(u32(i) / columns)} * cell
    p1 := p0 + cell
    f = {uv = {p0, {p1.x, p0.y}, p1, {p0.x, p1.y}}, size = size}
  }
  return frames
}

// sprite_frame shows frame `frame` (wrapped to its material's set) at a slot drawing a .SPRITE
// material: set it as an animation advances (sprite_clip_frame).
sprite_frame :: proc(self: ^Renderer, slot: $H, frame: u32) {
  slot := slot_index(slot)
  lock(self)
  if slot >= self.node_count do return
  node := &write_table(self, .NODES, Node)[slot]
  node.frame = sprite_frame_wrap(self, node.material_id, frame)
  mark_dirty(self, .NODES, int(slot))
}

// The frame wrapped to the set of material `material`; 0 without one.
@(private)
sprite_frame_wrap :: proc(self: ^Renderer, material: u32, frame: u32) -> u32 {
  first, live := sprite_frames_first(self, write_table(self, .MATERIALS, Material)[material].sprite_frames)
  if !live do return 0
  return frame % containers.ranges_size(&self.sprite_frame_ranges, first)
}

// SpriteClip is a run of frames played at fps: looping, or `once`, holding its last frame.
SpriteClip :: struct {
  first, count: u32,
  fps:          f32,
  once:         bool,
}

// sprite_clip_frame returns the frame a clip shows `time` seconds in, and whether a `once`
// clip has played through.
sprite_clip_frame :: proc(clip: SpriteClip, time: f32) -> (frame: u32, done: bool) {
  if clip.count == 0 do return clip.first, true
  step := u32(max(math.floor(time * clip.fps), 0))
  if clip.once do return clip.first + min(step, clip.count - 1), step >= clip.count
  return clip.first + step % clip.count, false
}
