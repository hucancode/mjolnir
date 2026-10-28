// The window, input and files of the machine the game runs on, desktop or web. Open a window,
// read input each tick and hand the window to your renderer.
package platform

// Layer 2: systems

// The host the game runs on: desktop (a GLFW window made with CLIENT_API = NO_API, the file
// system) or web (a canvas, no file system). Platform.window is the GLFW handle, or on the web the
// canvas selector, for a Vulkan or WebGPU renderer. native.odin is the desktop, js.odin the web.
// On the web, web/index.html is the host page holding the canvas (CANVAS_ID), copied beside the
// .wasm; it loads odin.js and, when present, wgpu.js for a WebGPU renderer.
