#+build js
package render

// The browser has no files: screenshot and FRAME_DUMP do nothing there.
#assert(FRAME_DUMP == "", "FRAME_DUMP is not available on the web")

@(private)
capture_mkdir :: proc(path: string) {}

@(private)
capture_write :: proc(path: string, width, height: int, rgb: []u8) -> bool {
  return false
}
