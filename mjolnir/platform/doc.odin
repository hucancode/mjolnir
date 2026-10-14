// The window and its input. Entry points: init, poll_events, read_input (fills an
// input.State), should_close, shutdown. window_glfw.odin is a GLFW window on the desktop,
// window_js.odin the page's canvas on the web; both feed input.Accumulator from their
// events, and the rest of the engine never touches either.
package platform
