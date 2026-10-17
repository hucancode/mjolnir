// The window, input and files of the machine the game runs on, desktop or web. Open a window,
// read input each tick and give the window to render.
package platform

// The host the engine runs on, desktop (a GLFW window, the file system) or web (a canvas, no
// file system); the rest of the engine names neither.
//   window and input: init, poll_events, read_input (fills an input.State), framebuffer_size,
//   dpi_scale, should_close, shutdown. Platform.window is what render.init takes.
//   run loop: run calls a step until it returns false; on the web the browser calls it each
//   animation frame and run returns at once. sleep idles until the next frame.
//   files: read_file, write_file. The engine itself takes and returns bytes.
// On the web, web/index.html is the host page holding the canvas (CANVAS_ID); `make web`
// copies it beside the .wasm.
// native.odin is the desktop, js.odin the web page. index.html loads odin.js and wgpu.js:
// the web takes the wgpu backend.
