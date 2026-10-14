#+build js
package mjolnir

import "base:runtime"

#assert(!USE_PARALLEL_UPDATE, "no threads on the web")

// The loop run started; the browser drives it through step_js.
@(private = "file")
web: struct {
  runner:  Runner,
  context_: runtime.Context,
  running: bool,
}

@(private)
run_loop :: proc(loop: Loop(byte)) {
  web.runner = {loop = loop}
  web.context_ = context
  web.running = true
}

// Called by odin.js each animation frame; false ends the loop.
@(export, link_name = "step")
step_js :: proc "contextless" (dt: f64) -> bool {
  context = web.context_
  if !web.running do return false
  if step(&web.runner) do return true
  web.running = false
  stop(&web.runner)
  return false
}
