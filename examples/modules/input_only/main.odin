// Platform and input on their own: a window with no renderer that reports every key, button, scroll and typed text; Escape quits. The command line prints the reports, the web page lists them over the canvas.
package main

import "core:fmt"
import "core:log"
import "mjolnir/input"
import "mjolnir/platform"

FRAMES :: #config(FRAMES, 0)

window: platform.Platform
state: input.State
frame: int

main :: proc() {
  context.logger = log.create_console_logger()
  if !platform.init(&window, 640, 360, "Input only") do return
  report("type, click, scroll or press Escape")
  platform.ready()
  platform.run(step)
}

step :: proc() -> bool {
  frame += 1
  if platform.should_close(&window) || input.key_pressed(&state, .ESCAPE) || (FRAMES > 0 && frame > FRAMES) {
    platform.shutdown(&window)
    return false
  }
  platform.poll_events(&window)
  platform.read_input(&window, &state)
  for it := 0; true; {
    key, pressed := input.next_key_edge(&state, &it) or_break
    report(fmt.tprintf("frame %d: %v %s", frame, key, "down" if pressed else "up"))
  }
  for b in input.MouseButton do if input.mouse_pressed(&state, b) do report(fmt.tprintf("frame %d: %v click at %v", frame, b, state.cursor))
  if state.scroll != {} do report(fmt.tprintf("frame %d: scroll %v", frame, state.scroll))
  if t := input.text(&state); t != "" do report(fmt.tprintf("frame %d: typed %q", frame, t))
  if moving := input.axis(&state, .A, .D); moving != 0 do report(fmt.tprintf("frame %d: A/D axis %v", frame, moving))
  free_all(context.temp_allocator)
  platform.sleep(16)
  return true
}
