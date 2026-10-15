// Mjolnir engine entry package: a fixed-rate main loop (run, Loop) and glTF
// scene instantiation (load_gltf) tying world, render and animation together.
// Everything else lives in the sub-packages. Imports point down the layers, never up:
//   4  the app (main.odin, examples)
//   3  mjolnir: the loop (on platform.run) and load_gltf
//   2  render/gltf, animation/gltf: glTF into render and animation
//   1  render, world, animation, physics, navigation, ui; platform (window, input, files, run loop)
//   0  render/vulkan or render/wgpu (picked by render), containers, geometry, font, input
// Each has one reason to change: render its rendering decisions, a backend its GPU API,
// platform the host (desktop or web). Nothing above platform reads files or names a host:
// the engine takes and returns bytes (#load them, or platform.read_file / write_file) and an
// opaque window handle.
package mjolnir
