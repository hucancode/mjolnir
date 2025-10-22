package main

import "core:log"
import "core:fmt"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "../../../mjolnir/render/retained_ui"

GameState :: struct {
  engine:             ^mjolnir.Engine,
  button_handle:      retained_ui.WidgetHandle,
  label_handle:       retained_ui.WidgetHandle,
  window_handle:      retained_ui.WidgetHandle,
  click_count:        int,
  background_visible: bool,
}

state: ^GameState

on_button_click :: proc(ctx: rawptr) {
  if state == nil do return
  state.click_count += 1
  log.infof("Button clicked! Count: %d", state.click_count)

  // Update label text
  ui := mjolnir.get_retained_ui(state.engine)
  label_text := fmt.tprintf("Clicks: %d", state.click_count)
  retained_ui.set_label_text(ui, state.label_handle, label_text)
}

on_toggle_click :: proc(ctx: rawptr) {
  if state == nil do return
  state.background_visible = !state.background_visible

  // In a real implementation, you'd toggle a background widget's visibility
  // retained_ui.set_visible(&state.ui, background_widget, state.background_visible)

  log.infof("Toggle clicked! Background visible: %v", state.background_visible)
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
    ui := mjolnir.get_retained_ui(engine)

    // Create a window container
    state.window_handle, _ = retained_ui.create_window(
      ui,
      "Retained UI Demo",
      50,
      50,
      700,
      500,
    )

    // Create some buttons
    button1, _ := retained_ui.create_button(
      ui,
      "Click Me!",
      100,
      120,
      200,
      50,
      on_button_click,
      nil,
      state.window_handle,
    )
    state.button_handle = button1

    button2, _ := retained_ui.create_button(
      ui,
      "Toggle Background",
      100,
      190,
      200,
      50,
      on_toggle_click,
      nil,
      state.window_handle,
    )

    // Create a label
    state.label_handle, _ = retained_ui.create_label(
      ui,
      "Clicks: 0",
      100,
      260,
      state.window_handle,
    )

    // Create another label with info
    info_label, _ := retained_ui.create_label(
      ui,
      "This is a retained mode UI demo",
      100,
      290,
      state.window_handle,
    )

    // Create an additional label showing the new API
    status_label, _ := retained_ui.create_label(
      ui,
      "Status: Ready",
      100,
      320,
      state.window_handle,
    )

    log.infof("Scene and UI setup complete")
  }
  // Run the engine
  mjolnir.run(engine, 800, 600, "visual-retained-ui")

  // Cleanup
  if state != nil do free(state)
}
