#+build js
package render

// The browser has no files: FRAME_DUMP does nothing there.
#assert(FRAME_DUMP == "", "FRAME_DUMP is not available on the web")

@(private)
dump_mkdir :: proc(path: string) {}

@(private)
dump_write :: proc(path: string, width, height: int, rgb: []u8) -> bool {
  return false
}
