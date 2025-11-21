package main

import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/render/retained_ui"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:fmt"
import "core:log"

GameState :: struct {
  engine:             ^mjolnir.Engine,
  button_handle:      retained_ui.WidgetHandle,
  label_handle:       retained_ui.WidgetHandle,
  status_label:       retained_ui.WidgetHandle,
  window_handle:      retained_ui.WidgetHandle,
  image_handle:       retained_ui.WidgetHandle,
  texture_handle:     resources.Image2DHandle,
  checkbox_handle:    retained_ui.WidgetHandle,
  combobox_handle:    retained_ui.WidgetHandle,
  textbox_handle:     retained_ui.WidgetHandle,
  click_count:        int,
  background_visible: bool,
  music_enabled:      bool,
}

state: ^GameState

// Static data for combobox items - must have stable memory address
quality_items := [?]string{"Low", "Medium", "High", "Ultra"}

on_button_click :: proc(ctx: rawptr) {
  if state == nil do return
  state.click_count += 1
  log.infof("Button clicked! Count: %d", state.click_count)
  // Update label text
  ui := &state.engine.render.retained_ui
  label_text := fmt.tprintf("Clicks: %d", state.click_count)
  retained_ui.set_label_text(ui, state.label_handle, label_text)
}

on_toggle_click :: proc(ctx: rawptr) {
  if state == nil do return
  state.background_visible = !state.background_visible
  // Toggle image visibility
  ui := &state.engine.render.retained_ui
  retained_ui.set_visible(ui, state.image_handle, state.background_visible)
  log.infof("Toggle clicked! Image visible: %v", state.background_visible)
}

on_checkbox_change :: proc(ctx: rawptr, checked: bool) {
  if state == nil do return
  state.music_enabled = checked
  ui := &state.engine.render.retained_ui
  status_text := "Status: Music OFF"
  if checked {
    status_text = "Status: Music ON"
  }
  retained_ui.set_label_text(ui, state.status_label, status_text)
  log.infof("Checkbox changed! Music enabled: %v", checked)
}

on_combobox_change :: proc(ctx: rawptr, selected_index: i32) {
  if state == nil do return
  ui := &state.engine.render.retained_ui
  quality_names := [?]string{"Low", "Medium", "High", "Ultra"}
  if selected_index >= 0 && selected_index < i32(len(quality_names)) {
    status_text := fmt.tprintf(
      "Status: Quality = %s",
      quality_names[selected_index],
    )
    retained_ui.set_label_text(ui, state.status_label, status_text)
    log.infof(
      "ComboBox changed! Selected index: %d (%s)",
      selected_index,
      quality_names[selected_index],
    )
  }
}

on_radio_easy :: proc(ctx: rawptr) {
  if state == nil do return
  ui := &state.engine.render.retained_ui
  retained_ui.set_label_text(
    ui,
    state.status_label,
    "Status: Difficulty = Easy",
  )
  log.infof("Difficulty set to Easy")
}

on_radio_normal :: proc(ctx: rawptr) {
  if state == nil do return
  ui := &state.engine.render.retained_ui
  retained_ui.set_label_text(
    ui,
    state.status_label,
    "Status: Difficulty = Normal",
  )
  log.infof("Difficulty set to Normal")
}

on_radio_hard :: proc(ctx: rawptr) {
  if state == nil do return
  ui := &state.engine.render.retained_ui
  retained_ui.set_label_text(
    ui,
    state.status_label,
    "Status: Difficulty = Hard",
  )
  log.infof("Difficulty set to Hard")
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  // Allocate game state
  state = new(GameState)
  // Setup callback - called once after engine initialization
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    log.infof("Setting up retained UI visual test...")
    // Store engine reference for callbacks
    state.engine = engine
    // Get the engine's built-in retained UI manager
    ui := &engine.render.retained_ui
    // Create a window container
    state.window_handle, _ = retained_ui.create_window(
      ui,
      "Retained UI Widget Showcase",
      20,
      20,
      760,
      560,
    )
    state.button_handle, _ = retained_ui.create_button(
      ui,
      "Click Me!",
      40,
      80,
      150,
      40,
      on_button_click,
      nil,
      state.window_handle,
    )
    state.label_handle, _ = retained_ui.create_label(
      ui,
      "Clicks: 0",
      40,
      130,
      state.window_handle,
      true, // autosize - test dynamic resizing
    )
    button2, _ := retained_ui.create_button(
      ui,
      "Toggle Image",
      40,
      160,
      150,
      40,
      on_toggle_click,
      nil,
      state.window_handle,
    )
    state.checkbox_handle, _ = retained_ui.create_checkbox(
      ui,
      "Enable Music",
      40,
      220,
      false,
      on_checkbox_change,
      nil,
      state.window_handle,
    )
    state.combobox_handle, _ = retained_ui.create_combobox(
      ui,
      quality_items[:],
      40,
      260,
      150,
      30,
      on_combobox_change,
      nil,
      state.window_handle,
    )
    retained_ui.create_label(
      ui,
      "Graphics Quality:",
      40,
      240,
      state.window_handle,
      true, // autosize
    )
    retained_ui.create_label(ui, "Difficulty:", 40, 330, state.window_handle, true)
    retained_ui.create_radiobutton(
      ui,
      1, // group_id
      "Easy",
      40,
      355,
      true, // selected by default
      on_radio_easy,
      nil,
      state.window_handle,
    )
    retained_ui.create_radiobutton(
      ui,
      1, // same group_id
      "Normal",
      40,
      385,
      false,
      on_radio_normal,
      nil,
      state.window_handle,
    )
    retained_ui.create_radiobutton(
      ui,
      1, // same group_id
      "Hard",
      40,
      415,
      false,
      on_radio_hard,
      nil,
      state.window_handle,
    )
    retained_ui.create_label(ui, "Player Name:", 40, 460, state.window_handle, true)
    state.textbox_handle, _ = retained_ui.create_textbox(
      ui,
      "Enter your name...",
      40,
      485,
      150,
      30,
      256,
      nil,
      nil,
      state.window_handle,
    )
    state.status_label, _ = retained_ui.create_label(
      ui,
      "Status: Ready",
      220,
      530,
      state.window_handle,
      true, // autosize
    )
    image_data := #load("statue-1275469_1280.jpg")
    state.texture_handle, _ = resources.create_texture_from_data(
      &engine.gctx,
      &engine.rm,
      image_data,
    )
    state.image_handle, _ = retained_ui.create_image(
      ui,
      state.texture_handle,
      420,
      80,
      320,
      240,
      state.window_handle,
    )
    // Initialize state
    state.background_visible = true
    log.infof("Scene and UI setup complete")
  }
  // Run the engine
  mjolnir.run(engine, 800, 600, "visual-retained-ui")
  // Cleanup
  if state != nil do free(state)
}
