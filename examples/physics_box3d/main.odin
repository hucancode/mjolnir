package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/render/mesh"
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
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
  phys:     b3.WorldId,
  pieces:   [dynamic]Piece,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  world_def := b3.DefaultWorldDef()
  world_def.gravity = {0, -9.81, 0}
  app.phys = b3.CreateWorld(world_def)
  defer b3.DestroyWorld(app.phys)
  defer delete(app.pieces)
  w := &app.window
  if !platform.init(w, 800, 600, "Physics (Box3D)") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Physics (Box3D)", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()

  setup(app)

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

spawn_mesh :: proc(app: ^App, m: render.MeshHandle, mat: render.MaterialHandle, parent: world.NodeHandle) -> world.NodeHandle {
  n := world.spawn_child(&app.scene, parent)
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

create_body :: proc(app: ^App, type: b3.BodyType, position: [3]f32) -> b3.BodyId {
  def := b3.DefaultBodyDef()
  def.type = type
  def.position = position
  return b3.CreateBody(app.phys, def)
}

setup :: proc(app: ^App) {
  ground_mesh := app.renderer.builtin_meshes[.CUBE]
  ground_mat := app.renderer.builtin_materials[.GRAY]
  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]
  sphere_mat := app.renderer.builtin_materials[.MAGENTA]
  cube_mesh := app.renderer.builtin_meshes[.CUBE]
  cube_mat := app.renderer.builtin_materials[.RED]
  rand_sphere := mesh.make_sphere()
  rand_cylinder := mesh.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.create_mesh(&app.renderer, rand_sphere)
  rand_cylinder_mesh := render.create_mesh(&app.renderer, rand_cylinder)
  rand_mat := app.renderer.builtin_materials[.WHITE]

  ground := world.spawn(&app.scene, {0, -0.5, 0})
  ground_body := create_body(app, .staticBody, {0, -0.5, 0})
  ground_hull := b3.MakeBoxHull(PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  _ = b3.CreateHullShape(ground_body, shape_def(0), &ground_hull.base)
  ground_visual := spawn_mesh(app, ground_mesh, ground_mat, ground)
  world.scale_xyz(&app.scene, ground_visual, PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  ball := world.spawn(&app.scene, {2.5, SPHERE_RADIUS, 0})
  ball_body := create_body(app, .staticBody, {2.5, SPHERE_RADIUS, 0})
  _ = b3.CreateSphereShape(ball_body, shape_def(0), &b3.Sphere{radius = SPHERE_RADIUS})
  ball_visual := spawn_mesh(app, sphere_mesh, sphere_mat, ball)
  world.scale(&app.scene, ball_visual, SPHERE_RADIUS)

  // Shared unit shapes; densities give every piece PIECE_MASS. CreateHullShape
  // clones the hull, so the cylinder is freed after setup.
  box_hull := b3.MakeBoxHull(1, 1, 1)
  cylinder_hull := b3.CreateCylinder(2.0, 1.0, 0, 16)
  defer b3.DestroyHull(cylinder_hull)
  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    body := create_body(app, .dynamicBody, pos)
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
  render.main_camera_look_at(&app.renderer, {30, 25, 30}, {0, 5, 0})
  light := world.spawn(&app.scene, {0, 20, 0})
  render.attach(&app.renderer, light.index, render.spot_light_attachment({0.8, 0.9, 1, 1}, 25.0, math.PI * 0.25))
  world.rotate(&app.scene, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
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
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
