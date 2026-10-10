package mjolnir

import "core:log"
import "core:thread"
import "core:time"
import "render"
import "platform"
import ui_module "ui"
import vk "vendor:vulkan"
import "world"

RENDER_FPS :: #config(RENDER_FPS, 60)
FRAME_TIME :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
UPDATE_FPS :: #config(UPDATE_FPS, RENDER_FPS)
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
UPDATE_FRAME_TIME_MILIS :: UPDATE_FRAME_TIME * 1_000.0
MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED :: 20
USE_PARALLEL_UPDATE :: #config(USE_PARALLEL_UPDATE, false)
FRAME_LIMIT :: #config(FRAME_LIMIT, 0)

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
KeyInputProc :: #type proc(engine: ^Engine, key: platform.Key, action: platform.Action)
MousePressProc :: #type proc(engine: ^Engine, button: platform.MouseButton, action: platform.Action)
MouseScrollProc :: #type proc(engine: ^Engine, offset: [2]f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: [2]f64)
PreRenderProc :: #type proc(engine: ^Engine)
PostRenderProc :: #type proc(engine: ^Engine)
// Extra inter-module glue (e.g. render.stage_bones), run on the update thread
// after the engine pushes world transform changes into render; see docs/glue.md.
SyncProc :: #type proc(engine: ^Engine)

Engine :: struct {
  platform:                  platform.Platform,
  world:                     world.World,
  last_frame_timestamp:      time.Time,
  last_update_timestamp:     time.Time,
  start_timestamp:           time.Time,
  setup_proc:                SetupProc,
  update_proc:               UpdateProc,
  sync_proc:                 SyncProc,
  key_press_proc:            KeyInputProc,
  mouse_press_proc:          MousePressProc,
  mouse_move_proc:           MouseMoveProc,
  mouse_scroll_proc:         MouseScrollProc,
  pre_render_proc:           PreRenderProc,
  post_render_proc:          PostRenderProc,
  // Drives the main camera each update from platform input. Assign another
  // controller to switch; the zero value disables camera control.
  camera_controller:         render.CameraController,
  ui:                        ui_module.System,
  render:                    render.Manager,
  debug_ui_enabled:          bool,
  show_engine_stats:         bool,
  update_active:             bool,
  // Deferred level teardown/setup requested mid-frame; applied at frame end so
  // GPU resources are never freed while command buffers still reference them.
  pending_teardown:          bool,
  pending_setup:             bool,
  // Opaque user pointer — stash app state here instead of using globals.
  user_data:                 rawptr,
}

// Request a level teardown, applied at the end of the current frame. Safe to call
// mid-frame (e.g. from a pre_render / update callback) — nothing is freed while
// the frame's command buffers are still in flight.
schedule_teardown :: proc(self: ^Engine) {
  self.pending_teardown = true
}

// Request a level setup, applied at the end of the current frame, after any
// pending teardown. Pair the two to reset a level: schedule_teardown then
// schedule_setup.
schedule_setup :: proc(self: ^Engine) {
  self.pending_setup = true
}

@(private)
apply_pending_lifecycle :: proc(self: ^Engine) {
  if self.pending_teardown {
    self.pending_teardown = false
    teardown(self)
  }
  if self.pending_setup {
    self.pending_setup = false
    setup(self)
  }
}

get_delta_time :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.last_update_timestamp)))
}

time_since_start :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.start_timestamp)))
}

init :: proc(
  self: ^Engine,
  width, height: u32,
  title: string,
) -> (
  ret: vk.Result,
) {
  if !platform.init(&self.platform, width, height, title) {
    return .ERROR_INITIALIZATION_FAILED
  }
  // Raw input lands in platform.input; events also feed the debug UI as they
  // arrive. User callbacks are dispatched once per tick in update.
  self.platform.hooks = debug_ui_hooks(self)
  render.create_instance(
    &self.render,
    title,
    platform.vulkan_instance_extensions(),
    platform.vulkan_get_instance_proc_addr(),
  ) or_return
  surface := platform.create_surface(&self.platform, render.vulkan_instance(&self.render)) or_return
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  if !world.init(&self.world) do return .ERROR_INITIALIZATION_FAILED
  if !ui_module.init(&self.ui) do return .ERROR_INITIALIZATION_FAILED
  render.init(
    &self.render,
    surface,
    platform.framebuffer_size(&self.platform),
    platform.dpi_scale(&self.platform),
  ) or_return
  self.camera_controller = render.orbit_controller()
  setup(self) or_return
  when FRAME_LIMIT > 0 {
    log.infof("Frame limit set to %d", FRAME_LIMIT)
  }
  log.infof("Engine initialized")
  return .SUCCESS
}

setup :: proc(self: ^Engine) -> (ret: vk.Result) {
  render.setup(&self.render) or_return
  defer if ret != .SUCCESS {
    render.teardown(&self.render)
  }
  if self.setup_proc != nil {
    self.setup_proc(self)
  }
  return .SUCCESS
}

// Level teardown, the counterpart to setup: the scene graph, every render
// slot and the cameras go. App-level resources (pools, pipelines, builtin
// meshes) stay; those belong to init/shutdown. State the app owns (physics,
// navigation) is torn down by the app.
teardown :: proc(self: ^Engine) {
  world.teardown(&self.world)
  render.teardown(&self.render)
}

// Camera controller input for this tick from the engine's input snapshot.
camera_input :: proc(self: ^Engine) -> render.CameraInput {
  inp := &self.platform.input
  ret := render.CameraInput {
    mouse_delta   = {f32(inp.mouse_delta.x), f32(inp.mouse_delta.y)},
    scroll        = f32(inp.scroll.y),
    drag          = platform.input_mouse_down(inp, .LEFT),
    mouse_blocked = render.debug_ui_wants_mouse(&self.render),
  }
  if render.debug_ui_wants_keyboard(&self.render) do return ret
  shift := platform.input_key_down(inp, .LEFT_SHIFT) || platform.input_key_down(inp, .RIGHT_SHIFT)
  ret.pan = shift
  ret.boost = shift
  axis :: proc(inp: ^platform.Input, neg, pos: platform.Key) -> f32 {
    return f32(int(platform.input_key_down(inp, pos))) - f32(int(platform.input_key_down(inp, neg)))
  }
  ret.move = {
    axis(inp, .A, .D),
    axis(inp, .Q, .E),
    axis(inp, .S, .W),
  }
  return ret
}

update :: proc(self: ^Engine) -> bool {
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  self.last_update_timestamp = time.now()
  // One input tick: snapshot the raw accumulator, route edges to the debug UI
  // and to user callbacks, all on the same cadence as the rest of update().
  platform.input_new_frame(&self.platform.input)
  inp := &self.platform.input
  buttons: [ui_module.MAX_MOUSE_BUTTONS]bool
  for down, b in inp.cur_buttons do buttons[int(b)] = down
  ui_module.process_mouse(&self.ui, {f32(inp.cur_mouse.x), f32(inp.cur_mouse.y)}, buttons)
  input_dispatch_callbacks(self)
  if cam, ok := render.main_camera(&self.render); ok {
    render.camera_controller_update(&self.camera_controller, cam, camera_input(self), delta_time)
  }
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  world.update(&self.world)
  for i in world.removed_nodes(&self.world) do render.stage_slot_removal(&self.render, i)
  for n in world.changed_nodes(&self.world) do render.stage_transform(&self.render, n.index, n.world_matrix, n.visible)
  if self.sync_proc != nil {
    self.sync_proc(self)
  }
  render.update(&self.render, delta_time)
  return true
}

shutdown :: proc(self: ^Engine) {
  teardown(self)
  render.shutdown(&self.render)
  ui_module.shutdown(&self.ui)
  world.shutdown(&self.world)
  platform.shutdown(&self.platform)
  log.infof("Engine deinitialized")
}

// One-stop entry point. Allocates the engine, installs a console logger,
// runs to window close, and tears down. Example:
//
//   main :: proc() {
//     mjolnir.run_app({ title = "Cube", setup = setup })
//   }
RunConfig :: struct {
  title:        string,
  width:        u32,             // 0 → 800
  height:       u32,             // 0 → 600
  setup:        SetupProc,
  update:       UpdateProc,
  sync:         SyncProc,
  pre_render:   PreRenderProc,
  post_render:  PostRenderProc,
  key_press:    KeyInputProc,
  mouse_press:  MousePressProc,
  mouse_move:   MouseMoveProc,
  mouse_scroll: MouseScrollProc,
  user_data:    rawptr,
  debug_ui:     bool,
  show_engine_stats: bool, // off by default; built-in Engine stats panel
}

run_app :: proc(cfg: RunConfig) {
  context.logger = log.create_console_logger()
  engine := new(Engine)
  defer free(engine)
  engine.setup_proc        = cfg.setup
  engine.update_proc       = cfg.update
  engine.sync_proc         = cfg.sync
  engine.pre_render_proc   = cfg.pre_render
  engine.post_render_proc  = cfg.post_render
  engine.key_press_proc    = cfg.key_press
  engine.mouse_press_proc  = cfg.mouse_press
  engine.mouse_move_proc   = cfg.mouse_move
  engine.mouse_scroll_proc = cfg.mouse_scroll
  engine.user_data         = cfg.user_data
  engine.debug_ui_enabled  = cfg.debug_ui
  engine.show_engine_stats = cfg.show_engine_stats
  w := cfg.width  if cfg.width  != 0 else 800
  h := cfg.height if cfg.height != 0 else 600
  run(engine, w, h, cfg.title)
}

run :: proc(self: ^Engine, width, height: u32, title: string) {
  if init(self, width, height, title) != .SUCCESS {
    return
  }
  defer shutdown(self)
  when USE_PARALLEL_UPDATE {
    self.update_active = true
    update_thread := thread.create(update_thread_proc)
    update_thread.data = self
    update_thread.init_context = context
    thread.start(update_thread)
    defer {
      self.update_active = false
      thread.join(update_thread)
      thread.destroy(update_thread)
    }
  }
  frame := 0
  render_error_count := 0
  for !platform.should_close(&self.platform) {
    platform.poll_events(&self.platform) // fills the raw input accumulator
    when !USE_PARALLEL_UPDATE {
      update(self) // gated internally to the update rate; snapshots input
    }
    remaining := FRAME_TIME_MILIS - time.duration_milliseconds(time.since(self.last_frame_timestamp))
    if remaining > 0 {
      // Don't oversleep past the next update tick (UPDATE_FPS may exceed
      // RENDER_FPS); keep input latency bounded to one tick.
      when !USE_PARALLEL_UPDATE {
        until_tick := UPDATE_FRAME_TIME_MILIS - time.duration_milliseconds(time.since(self.last_update_timestamp))
        if until_tick < remaining do remaining = until_tick
      }
      if remaining > 0.2 {
        time.sleep(time.Duration(remaining * f64(time.Millisecond)))
      }
      continue
    }
    self.last_frame_timestamp = time.now()
    render.set_debug_time(&self.render, time_since_start(self))
    render.debug_ui_begin(&self.render)
    if pixels, w, h, changed := ui_module.take_font_atlas(&self.ui); changed {
      render.stage_ui_font_atlas(&self.render, pixels, w, h)
    }
    render.stage_ui(&self.render, ui_module.build_commands(&self.ui))
    if self.pre_render_proc != nil {
      self.pre_render_proc(self)
    }
    if self.show_engine_stats {
      populate_debug_ui(self)
    }
    render.debug_ui_end(&self.render)
    res := render.frame(
      &self.render,
      platform.framebuffer_size(&self.platform),
      platform.dpi_scale(&self.platform),
      self.debug_ui_enabled,
    )
    if self.post_render_proc != nil {
      self.post_render_proc(self)
    }
    // Apply any teardown/setup requested during this frame now that the frame is
    // presented — safe point to free/recreate GPU resources (teardown waits idle).
    apply_pending_lifecycle(self)
    free_all(context.temp_allocator)
    if res != .SUCCESS {
      log.errorf("Error during rendering %v", res)
      render_error_count += 1
      if render_error_count >= MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED {
        log.errorf("Too many render errors, exiting...")
        break
      }
    } else {
      render_error_count = 0
    }
    frame += 1
    when FRAME_LIMIT > 0 {
      if frame >= FRAME_LIMIT {
        log.infof("Reached frame limit %d, exiting gracefully", FRAME_LIMIT)
        break
      }
    }
  }
}

update_thread_proc :: proc(thread: ^thread.Thread) {
  engine := cast(^Engine)thread.data
  for engine.update_active {
    if !update(engine) do time.sleep(time.Millisecond * 2)
    free_all(context.temp_allocator)
  }
  log.info("Update thread terminating")
}
