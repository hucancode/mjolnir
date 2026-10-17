// Physics engine via vendor:box3d.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import b3 "vendor:box3d"

NX :: #config(NX, 4)
NY :: #config(NY, 3)
NZ :: #config(NZ, 5)
PIECE_COUNT :: NX * NY * NZ
PIECE_MASS :: 50.0
SPHERE_RADIUS :: 3.0
PLANE_WIDTH :: max(10.0, NX * 0.8)
PLANE_HEIGHT :: max(10.0, NZ * 0.8)
KILL_Y :: -50.0

Piece :: struct {
  body: b3.BodyId,
  node: world.NodeHandle,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  phys:     b3.WorldId,
  pieces:   [dynamic]Piece,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  world_def := b3.DefaultWorldDef()
  world_def.gravity = {0, -9.81, 0}
  app.phys = b3.CreateWorld(world_def)
  w := &app.window
  if !platform.init(w, 800, 600, "Physics (Box3D)") do return
  if !render.init(&app.renderer, "Physics (Box3D)", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  delete(app.pieces)
  b3.DestroyWorld(app.phys)
  free(app)
}

spawn_mesh :: proc(app: ^App, m: render.MeshHandle, mat: render.MaterialHandle, parent: world.NodeHandle) -> world.NodeHandle {
  n := world.spawn(&app.scene, parent = parent)
  render.attach(&app.renderer, n.index, render.MeshAttachment{handle = m, material = mat, cast_shadow = true})
  return n
}

// Matches the mjolnir/physics body defaults.
shape_def :: proc(density: f32) -> b3.ShapeDef {
  def := b3.DefaultShapeDef()
  def.density = density
  def.baseMaterial.friction = 0.8
  def.baseMaterial.restitution = 0.2
  return def
}

body_create :: proc(app: ^App, type: b3.BodyType, position: [3]f32) -> b3.BodyId {
  def := b3.DefaultBodyDef()
  def.type = type
  def.position = position
  return b3.CreateBody(app.phys, def)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  ground_mesh := app.renderer.builtin_meshes[.CUBE]
  ground_mat := app.renderer.builtin_materials[.GRAY]
  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]
  sphere_mat := app.renderer.builtin_materials[.MAGENTA]
  cube_mesh := app.renderer.builtin_meshes[.CUBE]
  cube_mat := app.renderer.builtin_materials[.RED]
  rand_sphere := render.make_sphere()
  rand_cylinder := render.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.mesh_create(&app.renderer, rand_sphere)
  rand_cylinder_mesh := render.mesh_create(&app.renderer, rand_cylinder)
  rand_mat := app.renderer.builtin_materials[.WHITE]

  ground := world.spawn(&app.scene, {0, -0.5, 0})
  ground_body := body_create(app, .staticBody, {0, -0.5, 0})
  ground_hull := b3.MakeBoxHull(PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  _ = b3.CreateHullShape(ground_body, shape_def(0), &ground_hull.base)
  ground_visual := spawn_mesh(app, ground_mesh, ground_mat, ground)
  world.scale_xyz(&app.scene, ground_visual, PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  ball := world.spawn(&app.scene, {2.5, SPHERE_RADIUS, 0})
  ball_body := body_create(app, .staticBody, {2.5, SPHERE_RADIUS, 0})
  _ = b3.CreateSphereShape(ball_body, shape_def(0), &b3.Sphere{radius = SPHERE_RADIUS})
  ball_visual := spawn_mesh(app, sphere_mesh, sphere_mat, ball)
  world.scale(&app.scene, ball_visual, SPHERE_RADIUS)

  // Shared unit shapes; densities give every piece PIECE_MASS. CreateHullShape
  // clones the hull, so the cylinder is freed after setup. The hull spans
  // y in [yOffset, yOffset+height]; -1 centers it like the mesh.
  box_hull := b3.MakeBoxHull(1, 1, 1)
  cylinder_hull := b3.CreateCylinder(2.0, 1.0, -1.0, 16)
  defer b3.DestroyHull(cylinder_hull)
  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    body := body_create(app, .dynamicBody, pos)
    // Unit-sized shapes match the unit builtin meshes, so visuals need no scale.
    piece_mesh, piece_mat := rand_cylinder_mesh, rand_mat
    switch i % 3 {
    case 0:
      _ = b3.CreateHullShape(body, shape_def(PIECE_MASS / (2.0 * math.PI)), cylinder_hull)
    case 1:
      _ = b3.CreateHullShape(body, shape_def(PIECE_MASS / 8.0), &box_hull.base)
      piece_mesh, piece_mat = cube_mesh, cube_mat
    case 2:
      _ = b3.CreateSphereShape(body, shape_def(PIECE_MASS / (4.0 / 3.0 * math.PI)), &b3.Sphere{radius = 1.0})
      piece_mesh = rand_sphere_mesh
    }
    node := world.spawn(&app.scene, pos)
    spawn_mesh(app, piece_mesh, piece_mat, node)
    append(&app.pieces, Piece{body, node})
  }
  log.infof("Created %d Box3D bodies", PIECE_COUNT)
  render.camera_look_at(render.main_camera(&app.renderer), {30, 25, 30}, {0, 5, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {0, 20, 0})
  render.attach(&app.renderer, light.index, render.light_create(&app.renderer, render.make_spot_light({0.8, 0.9, 1, 1}, 25.0, math.PI * 0.25)))
  world.rotate(&app.scene, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  return true
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  b3.World_Step(app.phys, dt, 4)
  for i := len(app.pieces) - 1; i >= 0; i -= 1 {
    p := app.pieces[i]
    if !b3.Body_IsAwake(p.body) do continue
    pos := b3.Body_GetPosition(p.body)
    if pos.y < KILL_Y {
      b3.DestroyBody(p.body)
      world.despawn(&app.scene, p.node)
      unordered_remove(&app.pieces, i)
      continue
    }
    world.set_world_pose(&app.scene, p.node, pos, b3.Body_GetRotation(p.body))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
