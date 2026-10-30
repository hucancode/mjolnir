// Platform on its own: a window with no renderer that reports every key, button, gamepad button, scroll and typed text through input; F toggles fullscreen, L locks the cursor, C copies the frame number, Escape quits. The command line prints the reports, the web page lists them over the canvas.
package main

import "core:fmt"
import "core:log"
import "mjolnir/input"
import "mjolnir/platform"

FRAMES :: #config(FRAMES, 0)

window: platform.Platform
state: input.State
frame: int
locked: bool

main :: proc() {
  context.logger = log.create_console_logger()
  if !platform.init(&window, 640, 360, "Platform only") do return
  report("type, click, scroll, press a gamepad button, F, L, C or Escape")
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
  for pad in state.gamepads do for b in input.GamepadButton do if input.gamepad_pressed(&state, pad, b) do report(fmt.tprintf("frame %d: gamepad %d %v", frame, pad, b))
  if input.key_pressed(&state, .F) do platform.set_fullscreen(&window, !platform.is_fullscreen(&window))
  if input.key_pressed(&state, .L) {
    locked = !locked
    platform.set_cursor_mode(&window, .LOCKED if locked else .NORMAL)
  }
  if input.key_pressed(&state, .C) do platform.set_clipboard(&window, fmt.tprintf("frame %d", frame))
  platform.set_title(&window, fmt.tprintf("Platform only: frame %d", frame))
  if moving := input.axis(&state, .A, .D); moving != 0 do report(fmt.tprintf("frame %d: A/D axis %v", frame, moving))
  free_all(context.temp_allocator)
  platform.sleep(16)
  return true
}
