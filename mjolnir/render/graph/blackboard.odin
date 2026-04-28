package graph

import "core:mem"

BlackboardEntry :: struct {
  type:   typeid,
  offset: int,
}

Blackboard :: struct {
  buf:   []u8,
  used:  int,
  index: map[string]BlackboardEntry,
}

blackboard_init :: proc(bb: ^Blackboard, size: int) {
  bb.buf = make([]u8, size)
  bb.used = 0
  bb.index = make(map[string]BlackboardEntry)
}

blackboard_destroy :: proc(bb: ^Blackboard) {
  delete(bb.buf)
  delete(bb.index)
}

blackboard_reset :: proc(bb: ^Blackboard) {
  bb.used = 0
  clear(&bb.index)
}

@(private = "file")
align_up :: #force_inline proc(off, align: int) -> int {
  return (off + align - 1) & ~(align - 1)
}

// Reserve `size` bytes aligned to `align` from the bump arena.
// Returns offset; -1 on overflow.
@(private = "file")
bb_bump :: proc(bb: ^Blackboard, size, align: int) -> int {
  off := align_up(bb.used, align)
  end := off + size
  if end > len(bb.buf) do return -1
  bb.used = end
  return off
}

// Add typed entry under `key`. If key exists with same type, returns existing
// pointer (no realloc, no zero). If type mismatches, overwrites entry.
blackboard_add :: proc(bb: ^Blackboard, key: string, $T: typeid) -> ^T {
  if e, ok := bb.index[key]; ok && e.type == typeid_of(T) {
    return cast(^T)&bb.buf[e.offset]
  }
  size := size_of(T)
  align := align_of(T)
  off := bb_bump(bb, size, align)
  if off < 0 do return nil
  bb.index[key] = BlackboardEntry{
    type   = typeid_of(T),
    offset = off,
  }
  ptr := cast(^T)&bb.buf[off]
  mem.zero(ptr, size)
  return ptr
}

blackboard_get :: proc(bb: ^Blackboard, key: string, $T: typeid) -> ^T {
  e, ok := bb.index[key]
  if !ok || e.type != typeid_of(T) do return nil
  return cast(^T)&bb.buf[e.offset]
}

blackboard_has :: proc(bb: ^Blackboard, key: string) -> bool {
  _, ok := bb.index[key]
  return ok
}
