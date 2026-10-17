// FABRIK with bend-cone constraints.
package main

import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"
import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/animation"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

scene: gltf.Scene
rig: ^animation.Rig
animator: animation.Animator
animation_time: f32 = 0
spider_root_node: world.NodeHandle
mesh_node: world.NodeHandle
ground_plane: world.NodeHandle

leg_targets: [6][3]f32
leg_layers: [6]Maybe(animation.LayerHandle)

body_amplitude: mu.Real = 2.5
body_speed: mu.Real = 0.15
leg_lift: mu.Real = 2.5
ik_weight: mu.Real = 1.0
paused: bool = false
show_markers: bool = true
manual_feet: bool = false
foot_y: [6]mu.Real = {0, 0, 0, 0, 0, 0}

LEG_NAMES := [6]string{"FR", "MR", "BR", "FL", "ML", "BL"}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "IK") do return
  if !render.init(&app.renderer, "IK", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 20, 20}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  scene = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/spider.glb"))
  if len(scene.roots) == 0 || len(scene.skinned) == 0 do return true
  spider_root_node = scene.roots[0]
  world.translate(&app.scene, spider_root_node, [3]f32{0, 5, 0})
  mesh_node = scene.skinned[0].node
  rig = &scene.rigs[scene.skinned[0].rig]
  skel := &rig.skeleton
  animation.animator_init(&animator, rig)

  leg_configs := []struct{root_name, tip_name: string}{
    {"leg_front_r_0", "leg_front_r_5"},
    {"leg_middle_r_0", "leg_middle_r_5"},
    {"leg_back_r_0", "leg_back_r_5"},
    {"leg_front_l_0", "leg_front_l_5"},
    {"leg_middle_l_0", "leg_middle_l_5"},
    {"leg_back_l_0", "leg_back_l_5"},
  }

  body_pos := [3]f32{0, 5, 0}
  deg30 := f32(math.PI / 6.0)
  deg90 := f32(math.PI / 2.0)

  for i in 0 ..< 6 {
    tip_local, has_tip := animation.rest_position(skel, leg_configs[i].tip_name)
    if !has_tip {
      log.warnf("Leg %d: tip %s missing", i, leg_configs[i].tip_name)
      continue
    }
    leg_targets[i] = {tip_local.x + body_pos.x, 0, tip_local.z + body_pos.z}

    pole_pos := [3]f32{0, 10, 0}
    if root_local, has_root := animation.rest_position(skel, leg_configs[i].root_name); has_root {
      root_world := root_local + body_pos
      pole_pos = {root_world.x * 0.5, root_world.y + 10, root_world.z * 0.5}
    }

    bones, _ := animation.bone_chain(skel, leg_configs[i].root_name, leg_configs[i].tip_name, context.temp_allocator)
    // the hip swings 30 degrees, the other joints 90
    for b, k in bones do animation.bone_limits(&animator)[b] = {{deg30, deg90, deg30} if k == 0 else {deg90, deg90, deg90}}
    ik := animation.IKParams{target = leg_targets[i], pole = pole_pos, pole_weight = 1, space = .WORLD}
    if idx, ok := animation.layer_create(&animator, rig, ik, bones); ok {
      leg_layers[i] = idx
    } else {
      log.errorf("IK layer add failed leg %d", i)
    }
  }

  ground_plane = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground_plane.index), render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, ground_plane, [3]f32{40, 0.2, 40})
  light := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 1, 1, 1}, 10.0)))
  return true
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&scene)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  if !paused do animation_time += dt
  amp := f32(body_amplitude)
  spd := f32(body_speed)
  lift := f32(leg_lift)

  body_x := amp * math.sin(animation_time * spd * 2 * math.PI)
  body_pos := [3]f32{body_x, 0, 0}
  world.translate(&app.scene, spider_root_node, body_pos)

  for i in 0 ..< 6 {
    pole_pos := [3]f32{leg_targets[i].x * 0.5 + body_pos.x * 0.5, 5, leg_targets[i].z * 0.5}
    target_pos := leg_targets[i]
    if manual_feet {
      target_pos.y += f32(foot_y[i])
    } else {
      target_pos.y += lift * math.max(math.sin(animation_time * spd * math.PI), 0)
    }
    if layer, ok := leg_layers[i].?; ok {
      if p, ok := animation.layer_params(&animator, layer, animation.IKParams); ok do p.target, p.pole = target_pos, pole_pos
      animation.layer_fade(&animator, layer, f32(ik_weight))
    }
    if show_markers {
      render.debug_sphere(&app.renderer, target_pos, 0.5, {1, 0.2, 0.2, 1})
      render.debug_sphere(&app.renderer, pole_pos, 0.3, {0.3, 0.5, 1, 1})
    }
  }
  if rig != nil do animation.animator_update(&animator, rig, dt, world.world_matrix(&app.scene, mesh_node))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if rig != nil do render.stage_bones(&app.renderer, render.SlotHandle(mesh_node.index), animator.palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "IK", {480, 20, 300, 560}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Pause", &paused)
    mu.checkbox(ctx, "Show markers", &show_markers)
    mu.label(ctx, fmt.tprintf("Body amplitude: %.2f", body_amplitude))
    mu.slider(ctx, &body_amplitude, 0.0, 6.0)
    mu.label(ctx, fmt.tprintf("Body speed: %.2f", body_speed))
    mu.slider(ctx, &body_speed, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("IK weight: %.2f", ik_weight))
    mu.slider(ctx, &ik_weight, 0.0, 1.0)
    mu.checkbox(ctx, "Manual feet Y", &manual_feet)
    if manual_feet {
      for i in 0 ..< 6 {
        mu.label(ctx, fmt.tprintf("%s foot Y: %.2f", LEG_NAMES[i], foot_y[i]))
        mu.slider(ctx, &foot_y[i], 0.0, 6.0)
      }
    } else {
      mu.label(ctx, fmt.tprintf("Leg lift: %.2f", leg_lift))
      mu.slider(ctx, &leg_lift, 0.0, 6.0)
    }
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
