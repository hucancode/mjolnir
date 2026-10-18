#+build !js
#+private file
package ui

import "../font"
import "../input"
import "core:testing"

TEST_FONT :: #load("../../assets/Outfit-Regular.ttf")

VIEWPORT :: [2]f32{800, 600}

Fixture :: struct {
	ui:   UI,
	font: font.Font,
}

setup :: proc(f: ^Fixture) {
	init(&f.ui)
	font.init(&f.font, TEST_FONT, {})
}

teardown :: proc(f: ^Fixture) {
	shutdown(&f.ui)
	font.destroy(&f.font)
}

fixed :: proc(w, h: f32) -> [2]Size {
	return {{.FIXED, w}, {.FIXED, h}}
}

@(test)
test_row_flow_padding_gap_align :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	row := node_create(&f.ui, {size = fixed(300, 100), padding = {10, 20, 10, 20}, gap = 5, align = {.START, .CENTER}})
	a := node_create(&f.ui, {parent = row, size = fixed(50, 20)})
	b := node_create(&f.ui, {parent = row, size = fixed(30, 40)})
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
	testing.expect_value(t, rect(&f.ui, a), Rect{{10, 40}, {50, 20}})
	testing.expect_value(t, rect(&f.ui, b), Rect{{65, 30}, {30, 40}})
}

@(test)
test_column_fit_wraps_children :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	col := node_create(&f.ui, {direction = .COLUMN, padding = {1, 2, 3, 4}, gap = 10})
	node_create(&f.ui, {parent = col, size = fixed(50, 20)})
	node_create(&f.ui, {parent = col, size = fixed(70, 30)})
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
	testing.expect_value(t, len(f.ui.draw_order), 2)
	testing.expect_value(t, pick(&f.ui, {10, 10}), child)
	node(&f.ui, panel).hidden = true
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
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
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
	s: input.State
	s.cursor = {5, 5}
	s.buttons = {.LEFT}
	s.buttons_pressed = {.LEFT}
	update_input(&f.ui, &s)
	testing.expect_value(t, f.ui.hovered, label)
	testing.expect(t, hovered(&f.ui, button) && pressed(&f.ui, button) && focused(&f.ui, button), "label acts for the button")
	testing.expect(t, s.mouse_captured && s.keyboard_captured, "the UI holds the devices")
	s = {cursor = {5, 5}, buttons_released = {.LEFT}}
	update_input(&f.ui, &s)
	testing.expect(t, clicked(&f.ui, button), "released over the pressed button")
	testing.expect_value(t, f.ui.pressed, NodeHandle{})
	// a background that is not interactive lets the mouse through
	s = {cursor = {500, 500}}
	update_input(&f.ui, &s)
	testing.expect(t, !hovered(&f.ui, background) && !s.mouse_captured, "background passes the mouse")
}

@(test)
test_release_elsewhere_does_not_click :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	button := node_create(&f.ui, {size = fixed(100, 100), interactive = true})
	layout(&f.ui, VIEWPORT, VIEWPORT, &f.font)
	s := input.State{cursor = {5, 5}, buttons = {.LEFT}, buttons_pressed = {.LEFT}}
	update_input(&f.ui, &s)
	s = {cursor = {500, 500}, buttons_released = {.LEFT}}
	update_input(&f.ui, &s)
	testing.expect(t, !clicked(&f.ui, button), "released away from the button")
}

@(test)
test_pin_in_wider_window :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	left := node_create(&f.ui, {size = fixed(100, 50), offset = {10, 20}})
	right := node_create(&f.ui, {size = fixed(100, 50), offset = {690, 20}, pin = {.RIGHT, .TOP}})
	bottom := node_create(&f.ui, {size = fixed(100, 50), offset = {10, 530}, pin = {.LEFT, .BOTTOM}})
	stretch := node_create(&f.ui, {size = fixed(100, 50), offset = {10, 100}, pin = {.STRETCH, .TOP}})
	// 1600x600 is scale 1 with 800 extra width
	layout(&f.ui, VIEWPORT, {1600, 600}, &f.font)
	testing.expect_value(t, rect(&f.ui, left), Rect{{10, 20}, {100, 50}})
	testing.expect_value(t, rect(&f.ui, right), Rect{{1490, 20}, {100, 50}})
	testing.expect_value(t, rect(&f.ui, bottom), Rect{{10, 530}, {100, 50}})
	testing.expect_value(t, rect(&f.ui, stretch), Rect{{10, 100}, {900, 50}})
}

@(test)
test_scale_fits_one_axis :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	corner := node_create(&f.ui, {size = fixed(100, 50), offset = {700, 550}, pin = {.RIGHT, .BOTTOM}})
	label := node_create(&f.ui, {offset = {10, 10}, text = "hi", font_size = 20})
	// scale 2 (height fits); the window is 400 reference units wider
	layout(&f.ui, VIEWPORT, {2400, 1200}, &f.font)
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
	layout(&f.ui, VIEWPORT, {1600, 1200}, &f.font)
	s := input.State{cursor = {250, 250}}
	update_input(&f.ui, &s)
	testing.expect(t, hovered(&f.ui, button), "inside the scaled rect")
	s = {cursor = {150, 150}}
	update_input(&f.ui, &s)
	testing.expect(t, !hovered(&f.ui, button), "inside the reference rect but outside the scaled one")
}
