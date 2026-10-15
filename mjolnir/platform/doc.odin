// Package platform is everything that differs between the hosts the engine runs on: native.odin
// is the desktop (a GLFW window, the file system, a blocking loop), js.odin the web page (its
// canvas, no file system, the browser's animation frames). It changes when a host does; the rest
// of the engine names neither host.
//   window and input: init, poll_events, read_input (fills an input.State), framebuffer_size,
//   dpi_scale, should_close, shutdown. Platform.window is what render.init takes.
//   run loop: run calls a step until it returns false (on the web odin.js calls it through
//   the exported `step`, and run returns at once); sleep idles until the next frame.
//   files: read_file, write_file. The engine itself takes and returns bytes (render, glTF,
//   navigation meshes) and touches no file.
//   web/index.html: the host page, holding the canvas (CANVAS_ID) and loading odin.js and
//   wgpu.js (the web takes the wgpu backend); `make web` copies it beside the .wasm.
package platform
