package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/render/mesh"
import "../../mjolnir/physics"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

NX :: #config(NX, 4)
NY :: #config(NY, 3)
NZ :: #config(NZ, 5)
PIECE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0
PLANE_WIDTH :: max(10.0, NX * 0.8)
PLANE_HEIGHT :: max(10.0, NZ * 0.8)

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
}

phys: physics.World

main :: proc() {
  context.logger = log.create_console_logger()
  physics.init(&phys)
  defer physics.shutdown(&phys)
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Physics") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Physics", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  physics.create_body(&phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {PLANE_WIDTH, 0.5, PLANE_HEIGHT}}, user = world.Handle(ground))
  ground_visual := spawn_mesh(app, ground_mesh, ground_mat, ground)
  world.scale_xyz(&app.scene, ground_visual, PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  ball := world.spawn(&app.scene, {2.5, SPHERE_RADIUS, 0})
  physics.create_body(&phys, {2.5, SPHERE_RADIUS, 0}, collider = physics.SphereCollider{radius = SPHERE_RADIUS}, user = world.Handle(ball))
  ball_visual := spawn_mesh(app, sphere_mesh, sphere_mat, ball)
  world.scale(&app.scene, ball_visual, SPHERE_RADIUS)

  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    // Unit-sized colliders match the unit builtin meshes, so visuals need no scale.
    collider: physics.Collider
    piece_mesh, piece_mat := rand_cylinder_mesh, rand_mat
    switch i % 3 {
    case 0: collider = physics.CylinderCollider{radius = 1.0, height = 2.0}
    case 1: collider = physics.BoxCollider{half_extents = {1.0, 1.0, 1.0}}; piece_mesh, piece_mat = cube_mesh, cube_mat
    case 2: collider = physics.SphereCollider{radius = 1.0}; piece_mesh = rand_sphere_mesh
    }
    node := world.spawn(&app.scene, pos)
    physics.create_body(&phys, pos, mass = 50.0, collider = collider, user = world.Handle(node))
    spawn_mesh(app, piece_mesh, piece_mat, node)
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
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
  physics.step(&phys, dt)
  for k in phys.killed do world.despawn(&app.scene, world.NodeHandle(k.user))
  for b in physics.body_poses(&phys) do world.set_world_pose(&app.scene, world.NodeHandle(b.user), b.position, b.rotation)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
