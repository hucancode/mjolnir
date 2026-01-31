package main

import "../../mjolnir"
import "../../mjolnir/render/retained_ui"
import "../../mjolnir/resources"
import "core:fmt"
import "core:log"
import "core:math"

GameState :: struct {
	engine:          ^mjolnir.Engine,
	// Root container
	root:            retained_ui.FlexBoxHandle,
	// Widgets
	click_button:    retained_ui.ButtonWidget,
	toggle_button:   retained_ui.ButtonWidget,
	click_label:     retained_ui.LabelWidget,
	status_label:    retained_ui.LabelWidget,
	checkbox:        retained_ui.CheckboxWidget,
	dropdown:        retained_ui.DropdownWidget,
	text_input:      retained_ui.TextInputWidget,
	// Image elements
	image_element:   retained_ui.ElementHandle,
	texture_handle:  resources.Image2DHandle,
	// State
	click_count:     int,
	image_visible:   bool,
	music_enabled:   bool,
}

state: ^GameState

// Static data for dropdown items
quality_items := [?]string{"Low", "Medium", "High", "Ultra"}

// =============================================================================
// Callbacks
// =============================================================================

on_button_click :: proc(ctx: rawptr) {
	if state == nil do return
	state.click_count += 1
	log.infof("Button clicked! Count: %d", state.click_count)

	ui := &state.engine.render.retained_ui
	label_text := fmt.tprintf("Clicks: %d", state.click_count)
	retained_ui.set_label_text(ui, &state.click_label, label_text)
}

on_toggle_click :: proc(ctx: rawptr) {
	if state == nil do return
	state.image_visible = !state.image_visible

	ui := &state.engine.render.retained_ui
	retained_ui.set_visible(ui, state.image_element, state.image_visible)
	log.infof("Toggle clicked! Image visible: %v", state.image_visible)
}

on_checkbox_change :: proc(ctx: rawptr, checked: bool) {
	if state == nil do return
	state.music_enabled = checked

	ui := &state.engine.render.retained_ui
	status_text := checked ? "Status: Music ON" : "Status: Music OFF"
	retained_ui.set_label_text(ui, &state.status_label, status_text)
	log.infof("Checkbox changed! Music enabled: %v", checked)
}

on_dropdown_change :: proc(ctx: rawptr, selected_index: i32) {
	if state == nil do return

	ui := &state.engine.render.retained_ui
	if selected_index >= 0 && selected_index < i32(len(quality_items)) {
		status_text := fmt.tprintf("Status: Quality = %s", quality_items[selected_index])
		retained_ui.set_label_text(ui, &state.status_label, status_text)
		log.infof("Dropdown changed! Selected: %s", quality_items[selected_index])
	}
}

// =============================================================================
// Main
// =============================================================================

main :: proc() {
	context.logger = log.create_console_logger()
	engine := new(mjolnir.Engine)
	state = new(GameState)

	engine.setup_proc = proc(engine: ^mjolnir.Engine) {
		log.infof("Setting up retained UI visual test...")
		state.engine = engine

		ui := &engine.render.retained_ui

		// Create root FlexBox that fills the screen
		state.root = retained_ui.create_flexbox(ui)
		retained_ui.set_flexbox_size(ui, state.root, retained_ui.SizeAbsolute{760, 560})
		retained_ui.set_flexbox_position(ui, state.root, retained_ui.PosAbsolute{20, 20})
		retained_ui.set_flexbox_direction(ui, state.root, .COLUMN)
		retained_ui.set_flexbox_padding(ui, state.root, retained_ui.EdgeInsets{20, 20, 20, 20})
		retained_ui.set_flexbox_gap(ui, state.root, 10, 10)
		retained_ui.set_flexbox_background(ui, state.root, {240, 240, 240, 255})
		retained_ui.set_flexbox_border(ui, state.root, {100, 100, 120, 255}, 2)

		// Title
		title := retained_ui.create_text(
			ui,
			state.root,
			"Retained UI Widget Showcase",
			24,
			{80, 80, 120, 255},
		)

		// Create a horizontal container for buttons and image
		content_row := retained_ui.create_flexbox(ui, state.root)
		retained_ui.set_flexbox_size(ui, content_row, retained_ui.SizeAbsolute{720, 400})
		retained_ui.set_flexbox_direction(ui, content_row, .ROW)
		retained_ui.set_flexbox_gap(ui, content_row, 20, 0)

		// Left column for controls
		left_column := retained_ui.create_flexbox(ui, content_row)
		retained_ui.set_flexbox_size(ui, left_column, retained_ui.SizeAbsolute{350, 400})
		retained_ui.set_flexbox_direction(ui, left_column, .COLUMN)
		retained_ui.set_flexbox_gap(ui, left_column, 15, 0)

		// Click button
		state.click_button = retained_ui.create_button(
			ui,
			left_column,
			"Click Me!",
			on_button_click,
			nil,
			150,
			40,
		)

		// Click count label
		state.click_label = retained_ui.create_label(ui, left_column, "Clicks: 0")

		// Toggle button
		state.toggle_button = retained_ui.create_button(
			ui,
			left_column,
			"Toggle Image",
			on_toggle_click,
			nil,
			150,
			40,
		)

		// Checkbox
		state.checkbox = retained_ui.create_checkbox(
			ui,
			left_column,
			"Enable Music",
			false,
			on_checkbox_change,
		)

		// Dropdown label
		retained_ui.create_label(ui, left_column, "Graphics Quality:")

		// Dropdown
		state.dropdown = retained_ui.create_dropdown(
			ui,
			left_column,
			quality_items[:],
			150,
			30,
		)
		state.dropdown.callback = on_dropdown_change

		// Text input label
		retained_ui.create_label(ui, left_column, "Player Name:")

		// Text input
		state.text_input = retained_ui.create_text_input(
			ui,
			left_column,
			"Enter your name...",
			200,
			36,
		)

		// Right column for image
		right_column := retained_ui.create_flexbox(ui, content_row)
		retained_ui.set_flexbox_size(ui, right_column, retained_ui.SizeAbsolute{320, 400})
		retained_ui.set_flexbox_direction(ui, right_column, .COLUMN)
		retained_ui.set_flexbox_align(ui, right_column, .CENTER)
		retained_ui.set_flexbox_justify(ui, right_column, .CENTER)

		// Load image
		image_data := #load("statue-1275469_1280.jpg")
		state.texture_handle, _ = resources.create_texture_from_data(
			&engine.gctx,
			&engine.rm,
			image_data,
		)

		// Create image element
		state.image_element = retained_ui.create_image(
			ui,
			right_column,
			state.texture_handle,
			retained_ui.SizeAbsolute{300, 225},
		)

		// Status label at bottom
		status_row := retained_ui.create_flexbox(ui, state.root)
		retained_ui.set_flexbox_size(ui, status_row, retained_ui.SizeAbsolute{720, 30})
		retained_ui.set_flexbox_justify(ui, status_row, .CENTER)

		state.status_label = retained_ui.create_label(
			ui,
			status_row,
			"Status: Ready",
			14,
			{80, 80, 80, 255},
		)

		// Initialize state
		state.image_visible = true
		log.infof("Scene and UI setup complete")
	}

	// Run the engine
	mjolnir.run(engine, 800, 600, "visual-retained-ui")

	// Cleanup
	if state != nil {
		retained_ui.destroy_text_input(&engine.render.retained_ui, &state.text_input)
		retained_ui.destroy_dropdown(&engine.render.retained_ui, &state.dropdown)
		free(state)
	}
}
