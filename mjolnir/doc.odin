// Mjolnir is a game engine made of building blocks: each package does one job and your app glues
// them together. This package runs the main loop: fill a Loop with your callbacks and call run.
package mjolnir

// The engine is three layers; a package imports only from the layers below it:
//   3  glue: mjolnir (the loop), gltf (glTF into render, animation and world), debugui
//   2  systems: render, world, animation, physics, ui, platform, navigation (with bake and crowd).
//      They never import each other: the application passes data between them, e.g.
//      render.stage_transforms(&r, world.changes(&w)) or world.set_world_poses(&w, physics.body_poses(&p)).
//   1  foundation: containers, geometry, input, font, navigation/detour, navigation/recast
// Nothing above platform reads files or names a host: the engine takes and returns bytes
// (#load them, or platform.read_file / write_file) and an opaque window handle.
// An app builds its scene in Loop.setup once render.ready, and frees it in Loop.shutdown:
// on the web the device arrives after init, and main returns as soon as run does.
