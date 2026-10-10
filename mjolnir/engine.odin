package mjolnir

import "core:log"
import "core:os"
import "core:thread"
import "core:time"
import "input"
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
UI_FONT_PATH :: "assets/Outfit-Regular.ttf"
ENVIRONMENT_MAP_PATH :: "assets/Cannon_Exterior.hdr"
FRAME_LIMIT :: #config(FRAME_LIMIT, 0)

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
PreRenderProc :: #type proc(engine: ^Engine)
PostRenderProc :: #type proc(engine: ^Engine)

Engine :: struct {
  platform:                  platform.Platform,
  world:                     world.World,
  last_frame_timestamp:      time.Time,
  last_update_timestamp:     time.Time,
  start_timestamp:           time.Time,
  setup_proc:                SetupProc,
  update_proc:               UpdateProc,
  pre_render_proc:           PreRenderProc,
  post_render_proc:          PostRenderProc,
  // This tick's input, rebuilt at the start of each update. Read it in the
  // update callback, e.g. input.key_pressed(&engine.input, .SPACE).
  input:                     input.State,
  // Set each tick when the debug UI or the retained UI owns the device; skip
  // game reactions to that device while set.
  mouse_captured:            bool,
  keyboard_captured:         bool,
  // Drives the main camera each update from the input snapshot. Assign
  // another controller to switch; the zero value disables camera control.
  camera_controller:         render.CameraController,
  ui:                        ui_module.System,
  render:                    render.Manager,
  debug_ui_enabled:          bool,
  show_engine_stats:         bool,
  update_active:             bool,
  // Opaque user pointer — stash app state here instead of using globals.
  user_data:                 rawptr,
}

@(private)
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
  font, font_err := os.read_entire_file(UI_FONT_PATH, context.allocator)
  if font_err != nil {
    log.errorf("Failed to read UI font %s: %v", UI_FONT_PATH, font_err)
    return .ERROR_INITIALIZATION_FAILED
  }
  defer delete(font)
  if !ui_module.init(&self.ui, font) do return .ERROR_INITIALIZATION_FAILED
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
  if render.load_environment_map(&self.render, ENVIRONMENT_MAP_PATH) != .SUCCESS {
    log.warnf("Failed to load environment map %s", ENVIRONMENT_MAP_PATH)
  }
  if self.setup_proc != nil {
    self.setup_proc(self)
  }
  return .SUCCESS
}

// Level teardown, the counterpart to setup: the scene graph, every render
// slot and the cameras go. App-level resources (pools, pipelines, builtin
// meshes) stay; those belong to init/shutdown. State the app owns (physics,
// navigation) is torn down by the app. Call it from the update callback (not
// pre_render/post_render, which run while render builds the UI); pair with
// setup to reload a level.
teardown :: proc(self: ^Engine) {
  world.teardown(&self.world)
  render.teardown(&self.render)
}

update :: proc(self: ^Engine) -> bool {
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  self.last_update_timestamp = time.now()
  // One input tick: snapshot the accumulator, feed both UIs, then record who
  // owns each device so the camera and user code can skip captured input.
  input.new_frame(&self.input, &self.platform.input)
  render.debug_ui_input(&self.render, &self.input)
  // The debug UI draws on top, so the retained UI only sees input it doesn't take.
  debug_mouse := render.debug_ui_wants_mouse(&self.render)
  if !debug_mouse do ui_module.process_input(&self.ui, &self.input)
  self.mouse_captured = debug_mouse || ui_module.wants_mouse(&self.ui)
  self.keyboard_captured = render.debug_ui_wants_keyboard(&self.render) || ui_module.wants_keyboard(&self.ui)
  if cam, ok := render.main_camera(&self.render); ok {
    render.camera_controller_update(
      &self.camera_controller,
      cam,
      &self.input,
      delta_time,
      self.mouse_captured,
      self.keyboard_captured,
    )
  }
  // The update callback owns the per-tick glue between modules, including
  // world.update and the world -> render transform feed; see docs/glue.md.
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
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
  pre_render:   PreRenderProc,
  post_render:  PostRenderProc,
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
  engine.pre_render_proc   = cfg.pre_render
  engine.post_render_proc  = cfg.post_render
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
    platform.poll_events(&self.platform) // fills the input accumulator
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
