package main

import "../../mjolnir"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

Level_Data :: struct {
  engine: ^mjolnir.Engine,
  nodes:  [dynamic]resources.NodeHandle,
}

g_level_1_data: Level_Data
g_level_2_data: Level_Data

level_1_setup :: proc(user_data: rawptr) -> bool {
  data := cast(^Level_Data)user_data
  engine := data.engine
  log.info("Level 1 setup starting")
  nodes, ok := mjolnir.load_gltf(engine, "assets/Suzanne.glb")
  if !ok {
    log.error("Failed to load Suzanne.glb")
    return false
  }
  data.nodes = nodes
  log.infof("Level 1 loaded %d nodes", len(nodes))
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {0, 0, 3}, {0, 0, 0})
    sync_active_camera_controller(engine)
  }
  log.info("Level 1 setup complete")
  return true
}

level_1_teardown :: proc(user_data: rawptr) -> bool {
  data := cast(^Level_Data)user_data
  engine := data.engine
  log.info("Level 1 teardown starting")
  // CRITICAL: Make a local copy of the nodes array immediately to avoid data race
  // The async setup thread might modify data.nodes while we're tearing down
  nodes_to_cleanup := data.nodes
  data.nodes = nil // Clear the pointer immediately so setup can write new data
  if nodes_to_cleanup != nil {
    log.infof(
      "Level 1 scheduling %d nodes for deletion",
      len(nodes_to_cleanup),
    )
    for handle in nodes_to_cleanup {
      mjolnir.queue_node_deletion(engine, handle)
    }
    delete(nodes_to_cleanup)
  }
  log.info("Level 1 teardown complete")
  return true
}

level_2_setup :: proc(user_data: rawptr) -> bool {
  data := cast(^Level_Data)user_data
  engine := data.engine
  log.info("Level 2 setup starting")

  nodes, ok := mjolnir.load_gltf(engine, "assets/Mjolnir.glb")
  if !ok {
    log.error("Failed to load Mjolnir.glb")
    return false
  }
  data.nodes = nodes
  log.infof("Level 2 loaded %d nodes", len(nodes))

  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {0, 2, 5}, {0, 1, 0})
    sync_active_camera_controller(engine)
  }

  log.info("Level 2 setup complete")
  return true
}

level_2_teardown :: proc(user_data: rawptr) -> bool {
  data := cast(^Level_Data)user_data
  engine := data.engine
  log.info("Level 2 teardown starting")
  // CRITICAL: Make a local copy of the nodes array immediately to avoid data race
  // The async setup thread might modify data.nodes while we're tearing down
  nodes_to_cleanup := data.nodes
  data.nodes = nil // Clear the pointer immediately so setup can write new data

  if nodes_to_cleanup != nil {
    log.infof(
      "Level 2 scheduling %d nodes for deletion",
      len(nodes_to_cleanup),
    )
    for handle in nodes_to_cleanup {
      mjolnir.queue_node_deletion(engine, handle)
    }
    delete(nodes_to_cleanup)
  }
  log.info("Level 2 teardown complete")
  return true
}

on_level_loaded :: proc(user_data: rawptr) {
  log.info("Level transition complete!")
}

populate_level_test_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Level Test", {40, 250, 280, 250}, {.NO_CLOSE}) {
    if name, ok := mjolnir.get_current_level_id(&engine.level_manager); ok {
      mu.label(ctx, fmt.tprintf("Current Level: %s", name))
    } else {
      mu.label(ctx, "Current Level: None")
    }
    state := engine.level_manager.state
    state_text := ""
    switch state {
    case .Idle:
      state_text = "Idle"
    case .Tearing_Down:
      state_text = "Tearing Down..."
    case .Teardown_Complete:
      state_text = "Waiting (GPU Cleanup)..."
    case .Setting_Up:
      state_text = "Setting Up..."
    case .Setup_Complete:
      state_text = "Waiting (GPU Setup)..."
    }
    mu.label(ctx, fmt.tprintf("State: %s", state_text))

    is_transitioning := mjolnir.is_level_transitioning(&engine.level_manager)
    if !is_transitioning {
      current_name := "None"
      if name, ok := mjolnir.get_current_level_id(&engine.level_manager); ok {
        current_name = name
      }
      if .SUBMIT in mu.button(ctx, "Load LV1 (Blocking)") {
        log.infof(
          "========== Button pressed: Load Level 1 Blocking (currently: %s) ==========",
          current_name,
        )
        level_1_desc := mjolnir.Level_Descriptor {
          id        = "Level 1 - Suzanne",
          setup     = level_1_setup,
          teardown  = level_1_teardown,
          user_data = &g_level_1_data,
        }
        mjolnir.load_level(
          &engine.level_manager,
          level_1_desc,
          .Traditional,
          true,
          on_level_loaded,
        )
      }
      if .SUBMIT in mu.button(ctx, "Load LV2 (Blocking)") {
        log.infof(
          "========== Button pressed: Load Level 2 Blocking (currently: %s) ==========",
          current_name,
        )
        level_2_desc := mjolnir.Level_Descriptor {
          id        = "Level 2 - Mjolnir",
          setup     = level_2_setup,
          teardown  = level_2_teardown,
          user_data = &g_level_2_data,
        }
        mjolnir.load_level(
          &engine.level_manager,
          level_2_desc,
          .Traditional,
          true,
          on_level_loaded,
        )
      }

      if .SUBMIT in mu.button(ctx, "Load LV1 (Async)") {
        log.infof(
          "========== Button pressed: Load Level 1 Async (currently: %s) ==========",
          current_name,
        )
        level_1_desc := mjolnir.Level_Descriptor {
          id        = "Level 1 - Suzanne",
          setup     = level_1_setup,
          teardown  = level_1_teardown,
          user_data = &g_level_1_data,
        }
        mjolnir.load_level(
          &engine.level_manager,
          level_1_desc,
          .Seamless,
          false,
          on_level_loaded,
        )
      }
      if .SUBMIT in mu.button(ctx, "Load LV2 (Async)") {
        log.infof(
          "========== Button pressed: Load Level 2 Async (currently: %s) ==========",
          current_name,
        )
        level_2_desc := mjolnir.Level_Descriptor {
          id        = "Level 2 - Mjolnir",
          setup     = level_2_setup,
          teardown  = level_2_teardown,
          user_data = &g_level_2_data,
        }
        mjolnir.load_level(
          &engine.level_manager,
          level_2_desc,
          .Seamless,
          false,
          on_level_loaded,
        )
      }
    } else {
      mu.label(ctx, "(Transitioning...)")
    }
  }
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.debug_ui_enabled = true
  engine.post_render_proc = populate_level_test_ui

  // Initialize level data with engine pointer
  g_level_1_data.engine = engine
  g_level_2_data.engine = engine

  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    log.info("Loading initial level")
    level_1_desc := mjolnir.Level_Descriptor {
      id        = "Level 1 - Suzanne",
      setup     = level_1_setup,
      teardown  = level_1_teardown,
      user_data = &g_level_1_data,
    }
    mjolnir.load_level(
      &engine.level_manager,
      level_1_desc,
      .Traditional,
      false,
      on_level_loaded,
      nil,
    )
  }
  mjolnir.run(engine, 800, 600, "Level Management Test")
}
