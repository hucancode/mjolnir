// GLFW window and Vulkan surface glue. Entry points: init, poll_events,
// read_input (fills an input.State), should_close, shutdown. Window callbacks
// feed input.Accumulator; the rest of the engine never touches GLFW.
package platform
