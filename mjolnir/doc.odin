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
//
// API conventions, the same in every package:
//   make_x returns a value (make_point_light, make_material, make_cube); x_create stores one
//   and returns a handle (light_create); x_init fills a struct the caller owns (spline_init);
//   x_destroy frees either, ignoring a stale handle.
//   A getter returns a pointer to edit in place when only the application writes the data
//   (render.light, physics.body_params), and a copy when the system writes it too
//   (world.node, physics.body, crowd.agent). Getters that end in `ok` let it be omitted.
//   Maps: a module's init marks what it holds as kept; teardown frees everything made since
//   the mark at once. render.setup moves render's mark past what the application made after
//   init (shared textures, the debug UI atlas).
