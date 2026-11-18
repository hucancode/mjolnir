#+build !js
// Render past every reserve: a tiny Config, then more of each resource than it reserves, and 70 000 slots past the old 65 536 cap. Exits non-zero when a check fails: the slot with the highest index must be drawn, and no frame that grows may stall far past the steady ones (-define:HICCUP_MS=n).
package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:glfw"
import stbi "vendor:stb/image"
import "mjolnir/geometry"
import "mjolnir/render"

HICCUP_MS :: #config(HICCUP_MS, 30.0)

CONFIG :: render.Config {
  nodes            = 1024,
  meshes           = 4,
  materials        = 4,
  lights           = 2,
  emitters         = 2,
  force_fields     = 2,
  textures         = 8,
  bones            = 64,
  skinned_vertices = 64,
  sprite_frames    = 4,
  vertices         = 1024,
  indices          = 2048,
  skinning_data    = 64,
  overlay_vertices = 64,
  overlay_indices  = 96,
  gpu_buffers      = 2,
  shaders          = 2,
  particles        = 4096,
  debug_lines      = 256,
  shadow_maps      = 4,
}

SLOTS :: 70_000
PER_FRAME :: 5_000
RESOURCE_FRAMES :: 120
SPAWN_FRAME :: 150
SHOT_FRAME :: SPAWN_FRAME + SLOTS / PER_FRAME + 10
LAST_FRAME :: SHOT_FRAME + 60
TARGET :: render.SlotHandle(SLOTS - 1)

r: ^render.Renderer
failed: bool

check :: proc(ok: bool, format: string, args: ..any) {
  if ok do return
  log.errorf(format, ..args)
  failed = true
}

main :: proc() {
  context.logger = log.create_console_logger(.Info)
  if !glfw.Init() do os.exit(1)
  defer glfw.Terminate()
  glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
  window := glfw.CreateWindow(640, 360, "Render growth", nil, nil)
  r = new(render.Renderer)
  defer free(r)
  if !render.init(r, window, CONFIG) do os.exit(1)
  for !render.ready(r) do glfw.PollEvents()
  shot := "render_growth.png"
  cube := render.primitive(r, .CUBE, .GREEN)
  sun := render.light_create(r, render.make_directional_light())
  render.attach(r, render.SlotHandle(0), sun)
  render.place(r, render.SlotHandle(0), linalg.matrix4_from_quaternion(linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0})))
  render.main_camera(r)^ = render.make_camera({0, 0, 4}, {0, 0, 0})
  times := make([dynamic]f64, 0, LAST_FRAME)
  spawned := 1
  for frame := 0; frame < LAST_FRAME && !glfw.WindowShouldClose(window); frame += 1 {
    glfw.PollEvents()
    if frame < RESOURCE_FRAMES do grow_resources(frame)
    if frame >= SPAWN_FRAME && spawned < SLOTS - 1 {
      for _ in 0 ..< PER_FRAME do if spawned < SLOTS - 1 {
        x, z := f32(spawned % 300), f32(spawned / 300)
        render.attach(r, render.SlotHandle(spawned), cube)
        render.place(r, render.SlotHandle(spawned), linalg.matrix4_translate([3]f32{x - 150, -40, -z}) * linalg.matrix4_scale(f32(0.2)))
        spawned += 1
      }
      if spawned == SLOTS - 1 {
        render.attach(r, TARGET, render.primitive(r, .CUBE, .RED))
        render.place(r, TARGET, linalg.matrix4_scale(f32(0.8)))
      }
    }
    if frame == SHOT_FRAME do render.screenshot(r, shot)
    render.update(r, 1.0 / 60)
    start := time.tick_now()
    if !render.frame(r) do check(false, "frame %d failed", frame)
    append(&times, time.duration_milliseconds(time.tick_since(start)))
  }
  render.shutdown(r)
  if len(times) < LAST_FRAME do os.exit(1)
  steady := slice.clone(times[LAST_FRAME - 50:], context.temp_allocator)
  slice.sort(steady)
  median := steady[len(steady) / 2]
  worst, worst_frame := 0.0, 0
  for t, i in times[SPAWN_FRAME:SHOT_FRAME] do if t > worst {worst, worst_frame = t, SPAWN_FRAME + i}
  log.infof("steady frame %.2f ms, worst growth frame %.2f ms (frame %d)", median, worst, worst_frame)
  check(worst - median <= HICCUP_MS, "a growth frame stalled %.2f ms past the steady %.2f ms", worst - median, median)
  check_target(shot)
  os.remove(shot)
  if failed do os.exit(1)
  fmt.println("render_growth: every check passed")
}

grow_resources :: proc(frame: int) {
  slot := render.SlotHandle(SLOTS + frame)
  sphere := render.mesh_create(r, geometry.make_sphere(u32(8 + frame % 40), u32(8 + frame % 40)))
  check(sphere != 0, "mesh %d", frame)
  skinned := geometry.make_sphere(8, 8)
  skinned.skinnings = make([]geometry.SkinningData, len(skinned.vertices))
  check(render.mesh_create(r, skinned) != 0, "skinned mesh %d", frame)
  material := render.material_create(r, render.make_material(base_color_factor = {1, 1, 1, 1}))
  check(material != 0, "material %d", frame)
  pixels := make([]u8, 4 * 4 * 4, context.temp_allocator)
  texture := render.texture_create(r, pixels, {4, 4}, .RGBA8_UNORM)
  check(texture != 0, "texture %d", frame)
  check(render.bones_create(r, 16) != 0, "bones %d", frame)
  frames := [2]render.SpriteFrame{}
  check(render.sprite_frames_create(r, frames[:]) != 0, "sprite frames %d", frame)
  check(render.buffer_create(r, make([]u32, 16, context.temp_allocator)) != 0, "buffer %d", frame)
  light := render.light_create(r, render.make_point_light(intensity = 0.1))
  check(light != 0, "light %d", frame)
  emitter := render.emitter_create(r, render.make_emitter(emission_rate = 5))
  check(emitter != 0, "emitter %d", frame)
  field := render.force_field_create(r, render.make_force_field())
  check(field != 0, "force field %d", frame)
  switch frame % 4 {
  case 0: render.attach(r, slot, render.MeshAttachment{mesh = sphere, material = material})
  case 1: render.attach(r, slot, light)
  case 2: render.attach(r, slot, emitter)
  case 3: render.attach(r, slot, field)
  }
  render.place(r, slot, linalg.matrix4_translate([3]f32{f32(frame % 10) - 5, 3, -20}))
  if frame % 30 == 0 {
    filters := [?]render.CameraFilter {
      render.FILTER_ALL,
      render.FILTER_NO_POST,
      {types = {1, 2, 3, 4, 5, 6, 7}, clear = {0, 0, 0.2, 1}},
      {types = {0}, post = true},
    }
    check(render.camera_create(r, {64, 36}, render.make_camera(), filters[frame / 30 % len(filters)]) != 0, "camera %d", frame)
  }
  render.debug_axes(r, {0, f32(frame) * 0.01, 0})
}

check_target :: proc(path: string) {
  w, h, channels: i32
  cpath := strings.clone_to_cstring(path, context.temp_allocator)
  pixels := stbi.load(cpath, &w, &h, &channels, 4)
  if pixels == nil {
    check(false, "no screenshot at %s", path)
    return
  }
  defer stbi.image_free(pixels)
  centre := ([^]u8)(pixels)[(int(h / 2) * int(w) + int(w / 2)) * 4:][:4]
  check(int(centre[0]) > 2 * int(centre[1]) && int(centre[0]) > 2 * int(centre[2]), "slot %d is not drawn: the centre pixel is %v", TARGET, centre)
}
