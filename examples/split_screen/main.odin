package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

// Main camera lives at a faraway "display zone" and only sees the two display
// quads. Two RTT cameras observe the actual scene at the origin and pipe their
// final image into each quad's albedo.

DISPLAY_Y :: f32(100.0)

cam_a, cam_b: world.CameraHandle
mat_a, mat_b: world.MaterialHandle
spinner: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.post_render_proc = on_post_render
  mjolnir.run(engine, 1280, 720, "Split Screen")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.camera_controller_enabled = false

  // ---- Scene at origin ----
  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment{handle = ground_mesh, material = ground_mat, cast_shadow = false},
    ) or_else {}
  world.scale(&engine.world, ground, 8.0)

  world.spawn_primitive_mesh(&engine.world, .CUBE, .RED, position = {-2, 0.5, 0})
  world.spawn_primitive_mesh(&engine.world, .SPHERE, .GREEN, position = {0, 0.6, 1}, scale_factor = 0.6)
  world.spawn_primitive_mesh(&engine.world, .CONE, .BLUE, position = {2, 0.5, -1})
  spinner = world.spawn_primitive_mesh(&engine.world, .CUBE, .YELLOW, position = {0, 1.8, 0}, scale_factor = 0.4)

  world.spawn_light_directional(&engine.world, {4, 8, 4}, {1, 0.97, 0.92, 4.0}, 30.0, true)
  world.spawn_light_point(&engine.world, {-4, 6, -4}, {0.5, 0.7, 1.0, 2.0}, 15.0, false)

  // ---- Two off-screen cameras (perspective + top-down) ----
  cam_a = mjolnir.create_camera(
    engine, 640, 720,
    {.GEOMETRY, .LIGHTING, .TRANSPARENCY},
    {6, 4, 6}, {0, 1, 0},
    math.PI * 0.45, 0.1, 50.0,
  )
  cam_b = mjolnir.create_camera(
    engine, 640, 720,
    {.GEOMETRY, .LIGHTING, .TRANSPARENCY},
    {0, 10, 0.01}, {0, 0, 0},
    math.PI * 0.45, 0.1, 50.0,
  )

  // ---- Two display quads up in the "display zone" ----
  mat_a = world.create_material(&engine.world, {.ALBEDO_TEXTURE})
  mat_b = world.create_material(&engine.world, {.ALBEDO_TEXTURE})

  // QUAD_XY is 2x2 in local space; at scale 1, two side-by-side quads
  // centered at x=-1 and x=+1 cover x in [-2,2] (width 4), height 2.
  display_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XY)
  world.spawn(
    &engine.world,
    {-1.0, DISPLAY_Y, 0},
    world.MeshAttachment{handle = display_mesh, material = mat_a, cast_shadow = false},
  )
  world.spawn(
    &engine.world,
    {1.0, DISPLAY_Y, 0},
    world.MeshAttachment{handle = display_mesh, material = mat_b, cast_shadow = false},
  )

  // ---- Main camera framed on the two display quads ----
  width: u32 = 1280
  height: u32 = 720
  fov: f32 = math.PI * 0.5
  aspect := f32(width) / f32(height)
  // visible_width at distance d = 2 * d * tan(fov/2) * aspect
  // Want it == 4 (pair width). Height auto-matches because aspect=16/9 and
  // pair height = 2, visible_height = 2*d*tan(fov/2) -> 2*1.125*tan(45) = 2.25
  // good enough — small horizontal black bars are fine.
  d: f32 = 4.0 / (2.0 * math.tan(fov * 0.5) * aspect)
  if cam, ok := cont.get(engine.world.cameras, engine.world.main_camera); ok {
    cam.projection = world.PerspectiveProjection {
      fov = fov,
      aspect_ratio = aspect,
      near = 0.1,
      far = d * 2.0,
    }
    cam.extent = {width, height}
  }
  world.main_camera_look_at(&engine.world, {0, DISPLAY_Y, d}, {0, DISPLAY_Y, 0})
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  world.rotate(&engine.world, spinner, t, linalg.VECTOR3F32_Y_AXIS)
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  bind_camera_to_material(engine, cam_a, mat_a)
  bind_camera_to_material(engine, cam_b, mat_b)
}

bind_camera_to_material :: proc(
  engine: ^mjolnir.Engine,
  cam_h: world.CameraHandle,
  mat_h: world.MaterialHandle,
) {
  mat, ok := world.material(&engine.world, mat_h)
  if !ok do return
  mat.albedo = mjolnir.get_camera_attachment(engine, cam_h, .FINAL_IMAGE, engine.frame_index)
  world.stage_material_data(&engine.world.staging, mat_h)
}
