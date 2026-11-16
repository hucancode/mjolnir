#+build !js
#+private file
package ux

import "../containers"
import "../font"
import "../input"
import "../ui"
import "core:testing"

TEST_FONT :: #load("../../assets/Outfit-Regular.ttf")

VIEWPORT :: [2]f32{800, 600}

Fixture :: struct {
	ui:         UI,
	font:       font.Font,
	acc, input: input.State,
}

setup :: proc(f: ^Fixture) {
	init(&f.ui, VIEWPORT)
	font.init(&f.font, TEST_FONT, {})
}

teardown :: proc(f: ^Fixture) {
	shutdown(&f.ui)
	font.destroy(&f.font)
}

// What one input tick does besides moving the cursor.
Tick :: struct {
	left:      Maybe(input.Action), // the left button pressed or released
	held:      []input.Key, // down through the tick (shift, control)
	keys:      []input.Key, // pressed
	text:      string, // typed
	clipboard: string,
	scroll:    [2]f32,
}

// One tick: input with the cursor at `at`, then an update.
feed :: proc(f: ^Fixture, at: [2]f32, t: Tick = {}) {
	input.cursor_event(&f.acc, at)
	if a, ok := t.left.?; ok do input.button_event(&f.acc, .LEFT, a)
	for k in t.held do input.key_event(&f.acc, k, .PRESS)
	for k in t.keys do input.key_event(&f.acc, k, .PRESS)
	for r in t.text do input.char_event(&f.acc, r)
	if t.scroll != {} do input.scroll_event(&f.acc, t.scroll)
	input.drain(&f.acc, &f.input)
	for k in t.held do input.key_event(&f.acc, k, .RELEASE)
	for k in t.keys do input.key_event(&f.acc, k, .RELEASE)
	update_input(&f.ui, &f.input, t.clipboard)
	update(&f.ui, VIEWPORT, &f.font)
}

hover :: proc(f: ^Fixture, at: [2]f32) {
	feed(f, at)
}

// A left click at `at`: press, then release.
click_at :: proc(f: ^Fixture, at: [2]f32) {
	feed(f, at, {left = .PRESS})
	feed(f, at, {left = .RELEASE})
}

// Types into the focused text.
type :: proc(f: ^Fixture, t: Tick) {
	feed(f, f.input.cursor, t)
}

@(test)
test_row_flow_padding_gap_align :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	row := node_create(&f.ui, {size = fixed(300, 100), padding = {10, 20, 10, 20}, gap = 5, align = {.START, .CENTER}})
	a := node_create(&f.ui, {parent = row, size = fixed(50, 20)})
	b := node_create(&f.ui, {parent = row, size = fixed(30, 40)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, a), Rect{{10, 40}, {50, 20}})
	testing.expect_value(t, rect(&f.ui, b), Rect{{65, 30}, {30, 40}})
}

@(test)
test_stale_handle_reads_nothing :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	old := node_create(&f.ui, {size = fixed(50, 20)})
	node_destroy(&f.ui, old)
	reused := node_create(&f.ui, {size = fixed(70, 30)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, reused.index, old.index)
	testing.expect_value(t, rect(&f.ui, old), Rect{})
	testing.expect_value(t, rect(&f.ui, reused).size, [2]f32{70, 30})
}

@(test)
test_column_fit_wraps_children :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	col := node_create(&f.ui, {direction = .COLUMN, padding = {1, 2, 3, 4}, gap = 10})
	node_create(&f.ui, {parent = col, size = fixed(50, 20)})
	node_create(&f.ui, {parent = col, size = fixed(70, 30)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, col).size, [2]f32{70 + 4, 20 + 10 + 30 + 6})
}

@(test)
test_grow_shares_free_space_by_weight :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	row := node_create(&f.ui, {size = fixed(400, 50), gap = 10})
	node_create(&f.ui, {parent = row, size = fixed(90, 10)})
	g1 := node_create(&f.ui, {parent = row, size = {{.GROW, 1}, {.GROW, 0}}})
	g3 := node_create(&f.ui, {parent = row, size = {{.GROW, 3}, {.FIXED, 10}}})
	update(&f.ui, VIEWPORT, &f.font)
	// 400 - 90 - 2 gaps = 290, split 1:3
	testing.expect_value(t, rect(&f.ui, g1).size, [2]f32{72.5, 50})
	testing.expect_value(t, rect(&f.ui, g3).size.x, 217.5)
	testing.expect_value(t, rect(&f.ui, g3).pos.x, 90 + 10 + 72.5 + 10)
}

@(test)
test_percent_of_content_box :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	root := node_create(&f.ui, {size = fixed(220, 120), padding = {10, 10, 10, 10}})
	c := node_create(&f.ui, {parent = root, size = {{.PERCENT, 0.5}, {.PERCENT, 0.25}}})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, c).size, [2]f32{100, 25})
}

@(test)
test_absolute_anchor_pins_corner :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	screen := node_create(&f.ui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}})
	hud := node_create(&f.ui, {parent = screen, size = fixed(100, 40), position = .ABSOLUTE, anchor = {1, 0}, offset = {-8, 8}})
	panel := node_create(&f.ui, {size = fixed(200, 200), offset = {50, 50}})
	center := node_create(&f.ui, {parent = panel, size = fixed(20, 20), position = .ABSOLUTE, anchor = {0.5, 0.5}})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, hud).pos, [2]f32{800 - 100 - 8, 8})
	testing.expect_value(t, rect(&f.ui, center).pos, [2]f32{50 + 90, 50 + 90})
}

@(test)
test_hidden_parent_hides_subtree :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	panel := node_create(&f.ui, {size = fixed(100, 100), interactive = true})
	child := node_create(&f.ui, {parent = panel, size = fixed(50, 50)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, len(f.ui.draw_order), 2)
	testing.expect_value(t, pick(&f.ui, {10, 10}), child)
	node(&f.ui, panel).hidden = true
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, len(f.ui.draw_order), 0)
	testing.expect_value(t, pick(&f.ui, {10, 10}), NodeHandle{})
}

@(test)
test_hidden_child_takes_no_space :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	row := node_create(&f.ui, {})
	a := node_create(&f.ui, {parent = row, size = fixed(50, 10)})
	node_create(&f.ui, {parent = row, size = fixed(30, 10)})
	node(&f.ui, a).hidden = true
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, row).size.x, 30)
}

@(test)
test_clip_and_scroll :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	list := node_create(&f.ui, {size = fixed(100, 50), offset = {10, 10}, direction = .COLUMN, clip = true, scroll = {0, 30}, interactive = true})
	items: [4]NodeHandle
	for &it in items do it = node_create(&f.ui, {parent = list, size = fixed(100, 20)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, items[0]).pos, [2]f32{10, 10 - 30})
	testing.expect_value(t, clip(&f.ui, items[2]), Rect{{10, 10}, {100, 50}})
	// item 0 lies above the list: clipped away, so the list itself is hit
	testing.expect_value(t, pick(&f.ui, {20, 5}), NodeHandle{})
	testing.expect_value(t, pick(&f.ui, {20, 12}), items[1])
}

@(test)
test_text_fit_and_wrap :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	text := "the quick brown fox jumps over the lazy dog"
	one := node_create(&f.ui, {text = text, font_size = 16})
	wrapped := node_create(&f.ui, {text = text, font_size = 16, wrap = true, size = {{.FIXED, 120}, {}}})
	update(&f.ui, VIEWPORT, &f.font)
	lh := font.line_height(&f.font, 16)
	testing.expect_value(t, len(lines(&f.ui, one)), 1)
	testing.expect_value(t, rect(&f.ui, one).size.y, lh)
	ls := lines(&f.ui, wrapped)
	testing.expect(t, len(ls) > 2, "narrow text wraps")
	testing.expect_value(t, rect(&f.ui, wrapped).size.y, lh * f32(len(ls)))
	for l, k in ls {
		testing.expect(t, l.width <= 120, "lines fit the width")
		testing.expect_value(t, l.pos.y, rect(&f.ui, wrapped).pos.y + f32(k) * lh)
		if k > 0 do testing.expect_value(t, text[l.start - 1], ' ')
	}
	testing.expect_value(t, ls[len(ls) - 1].end, len(text))
}

@(test)
test_text_aligned_in_box :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	label := node_create(&f.ui, {text = "OK", font_size = 20, size = fixed(200, 50), align = {.CENTER, .CENTER}})
	update(&f.ui, VIEWPORT, &f.font)
	l := lines(&f.ui, label)[0]
	testing.expect_value(t, l.pos.x, (200 - l.width) / 2)
	testing.expect_value(t, l.pos.y, (50 - font.line_height(&f.font, 20)) / 2)
}

@(test)
test_draw_order_by_depth_then_tree :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	top := node_create(&f.ui, {size = fixed(10, 10), z = 5})
	a := node_create(&f.ui, {size = fixed(10, 10)})
	a_child := node_create(&f.ui, {parent = a, size = fixed(5, 5)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, f.ui.draw_order[0], a)
	testing.expect_value(t, f.ui.draw_order[1], a_child)
	testing.expect_value(t, f.ui.draw_order[2], top)
}

@(test)
test_destroy_removes_subtree :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	root := node_create(&f.ui, {text = "root"})
	child := node_create(&f.ui, {parent = root, text = "child"})
	grandchild := node_create(&f.ui, {parent = child})
	node_destroy(&f.ui, root)
	testing.expect(t, node(&f.ui, child) == nil && node(&f.ui, grandchild) == nil, "subtree freed")
}

@(test)
test_button_label_clicks_button :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	button := node_create(&f.ui, {size = fixed(200, 50), interactive = true, focusable = true})
	label := node_create(&f.ui, {parent = button, text = "Click", font_size = 16})
	background := node_create(&f.ui, {size = fixed(800, 600), z = -1})
	update(&f.ui, VIEWPORT, &f.font)
	s, acc: input.State
	input.cursor_event(&acc, {5, 5})
	input.button_event(&acc, .LEFT, .PRESS)
	input.drain(&acc, &s)
	update_input(&f.ui, &s)
	testing.expect_value(t, f.ui.hovered, label)
	testing.expect(t, hovered(&f.ui, button) && pressed(&f.ui, button) && focused(&f.ui, button), "label acts for the button")
	testing.expect(t, s.mouse_captured && s.keyboard_captured, "the UI holds the devices")
	input.button_event(&acc, .LEFT, .RELEASE)
	input.drain(&acc, &s)
	update_input(&f.ui, &s)
	testing.expect(t, clicked(&f.ui, button), "released over the pressed button")
	testing.expect_value(t, f.ui.pressed, NodeHandle{})
	// a background that is not interactive lets the mouse through
	input.cursor_event(&acc, {500, 500})
	input.drain(&acc, &s)
	update_input(&f.ui, &s)
	testing.expect(t, !hovered(&f.ui, background) && !s.mouse_captured, "background passes the mouse")
}

@(test)
test_release_elsewhere_does_not_click :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	button := node_create(&f.ui, {size = fixed(100, 100), interactive = true})
	update(&f.ui, VIEWPORT, &f.font)
	s, acc: input.State
	input.cursor_event(&acc, {5, 5})
	input.button_event(&acc, .LEFT, .PRESS)
	input.drain(&acc, &s)
	update_input(&f.ui, &s)
	input.cursor_event(&acc, {500, 500})
	input.button_event(&acc, .LEFT, .RELEASE)
	input.drain(&acc, &s)
	update_input(&f.ui, &s)
	testing.expect(t, !clicked(&f.ui, button), "released away from the button")
}

@(test)
test_roots_anchor_in_wider_window :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	left := node_create(&f.ui, {size = fixed(100, 50), offset = {10, 20}})
	right := node_create(&f.ui, {size = fixed(100, 50), anchor = {1, 0}, offset = {-10, 20}})
	bottom := node_create(&f.ui, {size = fixed(100, 50), anchor = {0, 1}, offset = {10, -20}})
	stretch := node_create(&f.ui, {size = {{.GROW, 0}, {.FIXED, 50}}, padding = {10, 0, 690, 0}, offset = {0, 100}})
	// 1600x600 is scale 1 with 800 extra width
	update(&f.ui, {1600, 600}, &f.font)
	testing.expect_value(t, rect(&f.ui, left), Rect{{10, 20}, {100, 50}})
	testing.expect_value(t, rect(&f.ui, right), Rect{{1490, 20}, {100, 50}})
	testing.expect_value(t, rect(&f.ui, bottom), Rect{{10, 530}, {100, 50}})
	testing.expect_value(t, rect(&f.ui, stretch), Rect{{0, 100}, {1600, 50}})
}

@(test)
test_scale_fits_one_axis :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	corner := node_create(&f.ui, {size = fixed(100, 50), anchor = {1, 1}})
	label := node_create(&f.ui, {offset = {10, 10}, text = "hi", font_size = 20})
	// scale 2 (height fits); the window is 400 reference units wider
	update(&f.ui, {2400, 1200}, &f.font)
	testing.expect_value(t, rect(&f.ui, corner), Rect{{2200, 1100}, {200, 100}})
	testing.expect_value(t, rect(&f.ui, label).pos, [2]f32{20, 20})
	lines := lines(&f.ui, label)
	testing.expect_value(t, lines[0].size, 40)
	testing.expect_value(t, lines[0].pos, [2]f32{20, 20})
}

@(test)
test_hit_test_in_scaled_window :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	button := node_create(&f.ui, {size = fixed(100, 100), offset = {100, 100}, interactive = true})
	update(&f.ui, {1600, 1200}, &f.font)
	s := input.State{cursor = {250, 250}}
	update_input(&f.ui, &s)
	testing.expect(t, hovered(&f.ui, button), "inside the scaled rect")
	s = {cursor = {150, 150}}
	update_input(&f.ui, &s)
	testing.expect(t, !hovered(&f.ui, button), "inside the reference rect but outside the scaled one")
}

@(test)
test_max_scroll_follows_overflow :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	list := node_create(&f.ui, {size = fixed(100, 50), direction = .COLUMN})
	for _ in 0 ..< 4 do node_create(&f.ui, {parent = list, size = fixed(100, 30)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, max_scroll(&f.ui, list), [2]f32{0, 70})
	node_destroy(&f.ui, list)
	testing.expect_value(t, containers.slots_count(&f.ui.slots), 0)
}

@(test)
test_update_redoes_only_what_changed :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	box := node_create(&f.ui, {size = fixed(100, 50)})
	label := node_create(&f.ui, {parent = box, text = "hi", font_size = 16})
	expect_update :: proc(t: ^testing.T, f: ^Fixture, laid_out, painted: bool, loc := #caller_location) {
		l, p := update(&f.ui, VIEWPORT, &f.font)
		testing.expect_value(t, l, laid_out, loc)
		testing.expect_value(t, p, painted, loc)
	}
	expect_update(t, &f, true, true)
	expect_update(t, &f, false, false)
	node(&f.ui, box).size.x = {.FIXED, 120}
	expect_update(t, &f, true, true)
	node(&f.ui, box).size.x = {.FIXED, 120}
	expect_update(t, &f, false, false)
	node(&f.ui, box).active = true
	expect_update(t, &f, false, true)
	f.ui.styles[0][.ACTIVE].fill = {255, 0, 0, 255}
	expect_update(t, &f, false, true)
	set_text(&f.ui, label, "hi")
	expect_update(t, &f, false, false)
	set_text(&f.ui, label, "hello")
	expect_update(t, &f, true, true)
	f.ui.reference = {400, 300}
	expect_update(t, &f, true, true)
	node_destroy(&f.ui, label)
	expect_update(t, &f, true, true)
}

@(test)
test_hover_repaints_in_the_hovered_look :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	look := Style{fill = {10, 10, 10, 255}}
	hot := Style{fill = {200, 200, 200, 255}}
	button_style := style_create(&f.ui, look, hot)
	button := node_create(&f.ui, {size = fixed(100, 40), interactive = true, style = button_style})
	update(&f.ui, VIEWPORT, &f.font)
	vertices, _, _ := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, vertices[0].color, look.fill)
	s := input.State{cursor = {50, 20}}
	update_input(&f.ui, &s)
	laid_out, painted := update(&f.ui, VIEWPORT, &f.font)
	testing.expect(t, !laid_out && painted, "hover repaints without a layout")
	vertices, _, _ = ui.mesh(canvas(&f.ui))
	testing.expect_value(t, vertices[0].color, hot.fill)
	_ = button
}

@(test)
test_label_takes_its_buttons_interaction :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	white, red := [4]u8{255, 255, 255, 255}, [4]u8{255, 0, 0, 255}
	label_style := style_create(&f.ui, {color = white}, Style{color = red})
	button := node_create(&f.ui, {size = fixed(200, 40), interactive = true})
	node_create(&f.ui, {parent = button, text = "Go", font_size = 16, style = label_style})
	update(&f.ui, VIEWPORT, &f.font)
	s := input.State{cursor = {190, 35}}
	update_input(&f.ui, &s)
	update(&f.ui, VIEWPORT, &f.font)
	vertices, _, batches := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, len(batches), 1)
	testing.expect_value(t, batches[0].texture, ui.FONT_TEXTURE)
	testing.expect_value(t, vertices[0].color, red)
}

@(test)
test_mesh_batches_by_texture_and_clip :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	solid := style_create(&f.ui, {fill = {255, 255, 255, 255}, border = 2, border_color = {0, 0, 0, 255}})
	panel := node_create(&f.ui, {size = fixed(200, 100), clip = true, style = solid})
	node_create(&f.ui, {parent = panel, size = fixed(20, 20), image = 9, image_uv = {{0.5, 0}, {1, 0}, {1, 0.25}, {0.5, 0.25}}})
	node_create(&f.ui, {parent = panel, text = "ok", font_size = 16})
	update(&f.ui, VIEWPORT, &f.font, 2)
	vertices, indices, batches := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, len(batches), 3)
	testing.expect_value(t, batches[0].texture, 0)
	testing.expect_value(t, batches[0].vertex_count, 5 * 4)
	testing.expect_value(t, batches[0].clip, Rect{{}, VIEWPORT})
	testing.expect_value(t, batches[1].texture, 9)
	testing.expect_value(t, batches[1].clip, Rect{{}, {200, 100}})
	first := vertices[batches[1].first_vertex:]
	testing.expect_value(t, first[0].uv, [2]f32{0.5, 0})
	testing.expect_value(t, first[2].uv, [2]f32{1, 0.25})
	testing.expect_value(t, first[2].pos, [2]f32{20, 20})
	testing.expect_value(t, batches[2].texture, ui.FONT_TEXTURE)
	atlas := font.atlas_size(&f.font)
	for v in vertices[batches[2].first_vertex:][:batches[2].vertex_count] {
		testing.expect(t, v.uv.x >= 0 && v.uv.x <= f32(atlas.x) && v.uv.y >= 0 && v.uv.y <= f32(atlas.y), "glyph uvs in atlas texels")
	}
	for b in batches do for i in indices[b.first_index:][:b.index_count] do testing.expect(t, i < b.vertex_count, "indices count from the batch")
}

@(test)
test_to_reference_inverts_the_fit :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	update(&f.ui, {1600, 1200}, &f.font)
	testing.expect_value(t, to_reference(&f.ui, {300, 100}), [2]f32{150, 50})
}

@(test)
test_wrapped_text_does_not_widen_its_parent :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	row := node_create(&f.ui, {size = fixed(200, 100)})
	column := node_create(&f.ui, {parent = row, direction = .COLUMN, size = {{.GROW, 0}, {}}})
	text := node_create(&f.ui, {parent = column, size = {{.GROW, 0}, {}}, wrap = true, font_size = 16, text = "a long paragraph that would be far wider than its column if it did not wrap"})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, column).size.x, 200)
	testing.expect(t, len(lines(&f.ui, text)) > 2, "wrapped to the column")
}

@(test)
test_clipping_grow_node_scrolls_instead_of_growing :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	panel := node_create(&f.ui, {direction = .COLUMN, size = fixed(100, 120)})
	list := node_create(&f.ui, {parent = panel, direction = .COLUMN, size = {{.GROW, 0}, {.GROW, 0}}, clip = true})
	for _ in 0 ..< 5 do node_create(&f.ui, {parent = list, size = fixed(100, 40)})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, list).size.y, 120)
	testing.expect_value(t, max_scroll(&f.ui, list), [2]f32{0, 80})
}

@(test)
test_tint_multiplies_down_the_subtree :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	solid := style_create(&f.ui, {fill = {255, 255, 255, 255}})
	panel := node_create(&f.ui, {size = fixed(100, 100), style = solid, tint = {255, 255, 255, 51}})
	node_create(&f.ui, {parent = panel, size = fixed(10, 10), style = solid, tint = {255, 0, 0, 255}})
	update(&f.ui, VIEWPORT, &f.font)
	vertices, _, _ := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, vertices[0].color, [4]u8{255, 255, 255, 51})
	testing.expect_value(t, vertices[4].color, [4]u8{255, 0, 0, 51})
	// a look only: no layout
	node(&f.ui, panel).tint = {}
	laid_out, painted := update(&f.ui, VIEWPORT, &f.font)
	testing.expect(t, !laid_out && painted, "tint repaints without a layout")
}

@(test)
test_truncated_line_fits_with_an_ellipsis :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	text := "a label far too long for its box"
	label := node_create(&f.ui, {size = {{.FIXED, 80}, {}}, text = text, truncate = true})
	update(&f.ui, VIEWPORT, &f.font)
	ls := lines(&f.ui, label)
	testing.expect_value(t, len(ls), 1)
	testing.expect(t, ls[0].ellipsis, "cut short")
	testing.expect(t, ls[0].end < len(text) && ls[0].end > 0, "keeps a prefix")
	testing.expect(t, ls[0].width <= 80, "fits its box")
	// a line that fits is left whole
	node(&f.ui, label).size.x = {.FIXED, 1000}
	update(&f.ui, VIEWPORT, &f.font)
	ls = lines(&f.ui, label)
	testing.expect(t, !ls[0].ellipsis && ls[0].end == len(text), "whole")
}

@(test)
test_text_takes_the_default_font_size :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	label := node_create(&f.ui, {text = "Hi"})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, lines(&f.ui, label)[0].size, f.ui.font_size)
	f.ui.font_size = 32
	laid_out, _ := update(&f.ui, VIEWPORT, &f.font)
	testing.expect(t, laid_out, "a new default lays out again")
	testing.expect_value(t, lines(&f.ui, label)[0].size, 32)
}

@(test)
test_skin_follows_the_interaction :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	normal := Style{skin = {image = 3, size = {30, 30}, border = {10, 10, 10, 10}}}
	hot := normal
	hot.skin.image = 4
	b := node_create(&f.ui, {size = fixed(100, 60), interactive = true, style = style_create(&f.ui, normal, hot)})
	update(&f.ui, VIEWPORT, &f.font)
	_, _, batches := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, len(batches), 1)
	testing.expect_value(t, batches[0].texture, 3)
	testing.expect_value(t, batches[0].vertex_count, 9 * 4)
	hover(&f, rect(&f.ui, b).pos + 5)
	update(&f.ui, VIEWPORT, &f.font)
	_, _, batches = ui.mesh(canvas(&f.ui))
	testing.expect_value(t, batches[0].texture, 4)
}

@(test)
test_raise_draws_above_same_z_siblings :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	a := node_create(&f.ui, {size = fixed(100, 100), interactive = true})
	b := node_create(&f.ui, {size = fixed(100, 100), interactive = true})
	top := node_create(&f.ui, {size = fixed(10, 10), z = 10})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, f.ui.draw_order[1], b)
	raise(&f.ui, a)
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, f.ui.draw_order[1], a)
	testing.expect_value(t, f.ui.draw_order[2], top)
	s, acc: input.State
	input.cursor_event(&acc, {50, 50})
	input.drain(&acc, &s)
	update_input(&f.ui, &s)
	testing.expect(t, hovered(&f.ui, a) && !hovered(&f.ui, b), "the raised node picks first")
}

@(test)
test_move_stops_at_window_edge :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	w := node_create(&f.ui, {size = fixed(80, 80), offset = {700, 0}})
	update(&f.ui, VIEWPORT, &f.font)
	move(&f.ui, w, {100, -30})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, w).pos, [2]f32{720, 0})
	move(&f.ui, w, {-50, 10})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, w).pos, [2]f32{670, 10})
}

@(test)
test_move_stays_inside_parent :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	panel := node_create(&f.ui, {size = fixed(200, 200), offset = {100, 100}})
	w := node_create(&f.ui, {parent = panel, position = .ABSOLUTE, size = fixed(50, 50)})
	update(&f.ui, VIEWPORT, &f.font)
	move(&f.ui, w, {-40, 500})
	update(&f.ui, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, w).pos, [2]f32{100, 250})
}

@(test)
test_move_pulls_back_after_shrink :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	w := node_create(&f.ui, {size = fixed(80, 80), offset = {700, 500}})
	update(&f.ui, VIEWPORT, &f.font)
	// the same height, narrower: the frame keeps its scale and loses width
	small := [2]f32{600, 600}
	update(&f.ui, small, &f.font)
	move(&f.ui, w, {})
	update(&f.ui, small, &f.font)
	r := rect(&f.ui, w)
	testing.expect(t, r.pos.x + r.size.x <= small.x + 0.001, "pulled back inside the window")
}

@(test)
test_move_scaled_window :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	w := node_create(&f.ui, {size = fixed(80, 80)})
	update(&f.ui, VIEWPORT * 2, &f.font)
	move(&f.ui, w, {40, 20})
	// a root is re-anchored where it lands: 40 of the 1440 window pixels it has room for
	testing.expect_value(t, node(&f.ui, w).anchor, [2]f32{40.0 / 1440, 20.0 / 1040})
	testing.expect_value(t, node(&f.ui, w).offset, [2]f32{})
	update(&f.ui, VIEWPORT * 2, &f.font)
	testing.expect_value(t, rect(&f.ui, w).pos, [2]f32{40, 20})
	// and keeps its place, proportionally, as the window grows
	update(&f.ui, VIEWPORT * 4, &f.font)
	testing.expect_value(t, rect(&f.ui, w).pos, [2]f32{80, 40})
}

// A focused text box holding `text`, its caret at the end.
editing :: proc(f: ^Fixture, text: string, width: f32 = 200) -> NodeHandle {
	box := text_box(&f.ui, {}, text, width)
	update(&f.ui, VIEWPORT, &f.font)
	r := rect(&f.ui, box)
	click_at(f, r.pos + r.size - 2)
	return box
}

@(test)
test_text_box_types_and_deletes :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	box := editing(&f, "")
	testing.expect(t, focused(&f.ui, box), "a click focuses it")
	testing.expect(t, rect(&f.ui, box).size.y > 10, "empty, it keeps a line's height")
	type(&f, {text = "héllo"})
	testing.expect_value(t, node(&f.ui, box).text, "héllo")
	testing.expect(t, changed(&f.ui, box), "typing changes it")
	type(&f, {keys = {.BACKSPACE}})
	type(&f, {keys = {.LEFT}})
	type(&f, {keys = {.LEFT}})
	type(&f, {keys = {.BACKSPACE}})
	testing.expect_value(t, node(&f.ui, box).text, "hll")
	type(&f, {keys = {.DELETE}})
	testing.expect_value(t, node(&f.ui, box).text, "hl")
	type(&f, {keys = {.HOME}})
	type(&f, {text = ">"})
	testing.expect_value(t, node(&f.ui, box).text, ">hl")
	type(&f, {keys = {.ENTER}})
	testing.expect(t, submitted(&f.ui, box), "enter submits")
	type(&f, {keys = {.ESCAPE}})
	testing.expect(t, !focused(&f.ui, box), "escape lets go")
	type(&f, {text = "x"})
	testing.expect_value(t, node(&f.ui, box).text, ">hl")
}

@(test)
test_text_box_selects_copies_and_pastes :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	box := editing(&f, "one two")
	type(&f, {held = {.LEFT_SHIFT}, keys = {.LEFT}})
	type(&f, {held = {.LEFT_SHIFT}, keys = {.LEFT}})
	type(&f, {held = {.LEFT_SHIFT}, keys = {.LEFT}})
	lo, hi := selection(&f.ui)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{4, 7})
	type(&f, {held = {.LEFT_CONTROL}, keys = {.X}})
	testing.expect_value(t, copied(&f.ui), "two")
	testing.expect_value(t, node(&f.ui, box).text, "one ")
	type(&f, {held = {.LEFT_SUPER}, keys = {.V}, clipboard = "2\nlines"})
	testing.expect_value(t, node(&f.ui, box).text, "one 2lines")
	type(&f, {held = {.LEFT_CONTROL}, keys = {.A}})
	type(&f, {text = "z"})
	testing.expect_value(t, node(&f.ui, box).text, "z")
	set_text(&f.ui, box, "")
	lo, hi = selection(&f.ui)
	testing.expect_value(t, hi, 0)
}

@(test)
test_text_box_click_places_the_caret :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	box := editing(&f, "abcdef")
	line := lines(&f.ui, box)[0]
	click_at(&f, line.pos + {font.measure(&f.font, "abc", line.size), 4})
	lo, hi := selection(&f.ui)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{3, 3})
	// shift-click extends from there
	end := line.pos + {line.width + 1, 4}
	feed(&f, end, {left = .PRESS, held = {.LEFT_SHIFT}})
	feed(&f, end, {left = .RELEASE})
	lo, hi = selection(&f.ui)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{3, 6})
}

@(test)
test_text_box_scrolls_to_the_caret :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	box := editing(&f, "", 60)
	type(&f, {text = "a long line that does not fit"})
	r := rect(&f.ui, box)
	x := caret_x(&f.ui, box, &f.font, len(node(&f.ui, box).text))
	testing.expect(t, node(&f.ui, box).scroll.x > 0, "the text scrolled")
	testing.expect(t, x <= r.pos.x + r.size.x && x >= r.pos.x, "the caret shows")
	type(&f, {keys = {.HOME}})
	testing.expect_value(t, node(&f.ui, box).scroll.x, 0)
}

@(test)
test_check_toggles :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	c := check(&f.ui, {}, "Sound")
	update(&f.ui, VIEWPORT, &f.font)
	click_at(&f, rect(&f.ui, c).pos + 4)
	testing.expect(t, node(&f.ui, c).active, "checked")
	testing.expect(t, changed(&f.ui, c), "changed the tick it flips")
	click_at(&f, rect(&f.ui, c).pos + 4)
	testing.expect(t, !node(&f.ui, c).active, "unchecked")
}

@(test)
test_window_drags_raises_and_closes :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	a, _, _ := window(&f.ui, "A", 200, {10, 10})
	b, _, close := window(&f.ui, "B", 200, {20, 20})
	update(&f.ui, VIEWPORT, &f.font)
	// a press on A's visible bar brings it over B
	feed(&f, {12, 15}, {left = .PRESS})
	testing.expect(t, node(&f.ui, a).order > node(&f.ui, b).order, "pressed to the front")
	feed(&f, {112, 65})
	feed(&f, {112, 65}, {left = .RELEASE})
	testing.expect_value(t, rect(&f.ui, a).pos, [2]f32{110, 60})
	click_at(&f, rect(&f.ui, close).pos + 4)
	testing.expect(t, node(&f.ui, b).hidden, "closed")
}

@(test)
test_slider_knob_drags_along_its_track :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	knob := slider(&f.ui, {}, 0, 112)
	update(&f.ui, VIEWPORT, &f.font)
	at := rect(&f.ui, knob).pos + 4
	feed(&f, at, {left = .PRESS})
	feed(&f, at + {50, 30})
	testing.expect_value(t, node(&f.ui, knob).anchor, [2]f32{0.5, 0.5})
	testing.expect(t, changed(&f.ui, knob), "dragging changes it")
	feed(&f, at + {500, 0})
	testing.expect_value(t, node(&f.ui, knob).anchor.x, 1)
}

@(test)
test_wheel_scrolls_the_clipping_node :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	view := scroll_view(&f.ui, {}, fixed(100, 100))
	for _ in 0 ..< 10 do node_create(&f.ui, {parent = view, size = fixed(50, 40)})
	update(&f.ui, VIEWPORT, &f.font)
	feed(&f, {50, 50}, {scroll = {0, -1}})
	testing.expect_value(t, node(&f.ui, view).scroll.y, f.ui.font_size * 3)
	feed(&f, {50, 50}, {scroll = {0, -100}})
	testing.expect_value(t, node(&f.ui, view).scroll.y, max_scroll(&f.ui, view).y)
}

@(test)
test_overlay_node_leaves_a_layer :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	style := style_create(&f.ui, {fill = {255, 0, 0, 255}})
	a := node_create(&f.ui, {size = fixed(10, 10), style = style, overlay = true})
	b := node_create(&f.ui, {size = fixed(10, 10), style = style})
	update(&f.ui, VIEWPORT, &f.font)
	_, _, batches := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, len(batches), 2)
	testing.expect_value(t, layer(&f.ui, a), 1)
	testing.expect_value(t, batches[0].z, 0)
	testing.expect_value(t, batches[1].z, 2)
	testing.expect_value(t, layer(&f.ui, b), 3)
}

@(test)
test_text_box_draws_a_caret_only_when_focused :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	box := text_box(&f.ui, {}, "", 200)
	update(&f.ui, VIEWPORT, &f.font)
	vertices, _, _ := ui.mesh(canvas(&f.ui))
	testing.expect_value(t, len(vertices), 5 * 4)
	focus(&f.ui, box)
	update(&f.ui, VIEWPORT, &f.font)
	vertices, _, _ = ui.mesh(canvas(&f.ui))
	testing.expect_value(t, len(vertices), 6 * 4)
}

@(test)
test_clicked_tells_the_button :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	b := node_create(&f.ui, {size = fixed(50, 50), interactive = true})
	update(&f.ui, VIEWPORT, &f.font)
	input.button_event(&f.acc, .RIGHT, .PRESS)
	feed(&f, {10, 10})
	input.button_event(&f.acc, .RIGHT, .RELEASE)
	feed(&f, {10, 10})
	testing.expect(t, clicked(&f.ui, b, .RIGHT), "right clicked")
	testing.expect(t, !clicked(&f.ui, b), "not left clicked")
}

@(test)
test_dropped_from_one_node_onto_another :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	a := node_create(&f.ui, {size = fixed(50, 50), offset = {0, 0}, interactive = true})
	icon := node_create(&f.ui, {parent = a, size = fixed(40, 40)})
	b := node_create(&f.ui, {size = fixed(50, 50), offset = {100, 0}, interactive = true})
	update(&f.ui, VIEWPORT, &f.font)
	feed(&f, {10, 10}, {left = .PRESS})
	feed(&f, {110, 10})
	feed(&f, {110, 10}, {left = .RELEASE})
	testing.expect(t, dropped(&f.ui, a, b), "dropped from a onto b")
	testing.expect(t, !dropped(&f.ui, b, a), "not the other way")
	testing.expect(t, !clicked(&f.ui, a) && !clicked(&f.ui, b), "a drop is no click")
	click_at(&f, {10, 10})
	testing.expect(t, !dropped(&f.ui, a, a) && !dropped(&f.ui, icon, b) && clicked(&f.ui, a), "a click is no drop")
}
