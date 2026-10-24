// Mjolnir is a game engine made of building blocks: each package does one job and your app glues
// them together. This package runs the main loop: fill a Loop with your callbacks and call run.
package mjolnir

// Layer 3: glue

// The engine has four layers; a package imports only from the layers below it:
//   3  glue: wires systems together
//   2  systems: each owns one part of a game's state. The application passes data between them, e.g.
//      render.stage_transforms(&r, world.changes(&w)) or world.set_world_poses(&w, physics.body_poses(&p)).
//   1  foundation: self-contained tools a system builds on, and the GPU backends
//
// API conventions, the same in every package:
//   make_x returns a value (make_point_light, make_material, make_cube); x_create stores one
//   and returns a handle (light_create); x_init fills a struct the caller owns (spline_init);
//   x_destroy frees either, ignoring a stale handle.
//   A getter returns a pointer to edit in place when only the application writes the data
//   (render.light, physics.body_params), and a copy when the system writes it too
//   (world.node, physics.body, navigation.agent). A getter that may miss returns (x, ok) #optional_ok, so ok can be omitted.
//   Maps: a module's init marks what it holds as kept; teardown frees everything made since
//   the mark at once. render.setup moves render's mark past what the application made after
//   init (shared textures, the debug UI atlas).
