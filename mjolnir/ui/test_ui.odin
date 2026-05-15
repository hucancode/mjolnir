package ui

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"

// init() needs no GPU, only allocates pool/staging/fontstash atlas.
// All tests below avoid GPU and font glyph rasterization.

@(test)
test_destroy_widget_invalidates_handle :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 16)
	defer shutdown(&sys)
	h, _ := create_quad2d(&sys, {10, 20}, {30, 40})
	destroy_widget(&sys, UIWidgetHandle(h))
	testing.expect(t, get_quad2d(&sys, h) == nil, "stale handle must miss")
}

// ---------------------------------------------------------------
// Box hierarchy + layout ----------------------------------------
// ---------------------------------------------------------------

@(test)
test_box_add_remove_child :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 8)
	defer shutdown(&sys)

	parent, _ := create_box(&sys, {0, 0}, {100, 100})
	child, _ := create_quad2d(&sys, {10, 10}, {20, 20})

	box_add_child(&sys, parent, UIWidgetHandle(child))
	pb := get_box(&sys, parent)
	testing.expect(t, len(pb.children) == 1, "child appended")
	cw := get_widget(&sys, UIWidgetHandle(child))
	parent_ref, has := get_widget_base(cw).parent.?
	testing.expect(t, has && parent_ref == UIWidgetHandle(parent), "child parent ref set")

	box_remove_child(&sys, parent, UIWidgetHandle(child))
	testing.expect(t, len(pb.children) == 0, "child removed")
	_, has2 := get_widget_base(cw).parent.?
	testing.expect(t, !has2, "child parent ref cleared")
}

@(test)
test_compute_layout_propagates_world_position :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 16)
	defer shutdown(&sys)

	root, _ := create_box(&sys, {100, 200}, {500, 500})
	mid, _ := create_box(&sys, {30, 40}, {200, 200})
	leaf, _ := create_quad2d(&sys, {5, 6}, {10, 10})
	box_add_child(&sys, root, UIWidgetHandle(mid))
	box_add_child(&sys, mid, UIWidgetHandle(leaf))

	compute_layout(&sys, UIWidgetHandle(root))

	rb := get_box(&sys, root)
	mb := get_box(&sys, mid)
	lq := get_quad2d(&sys, leaf)
	testing.expect(t, rb.world_position == [2]f32{100, 200}, "root world == position")
	testing.expect(t, mb.world_position == [2]f32{130, 240}, "mid world == root + mid local")
	testing.expect(t, lq.world_position == [2]f32{135, 246}, "leaf world == mid + leaf local")
}

@(test)
test_compute_layout_all_skips_orphans :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 8)
	defer shutdown(&sys)

	a, _ := create_quad2d(&sys, {1, 1}, {1, 1})
	b, _ := create_quad2d(&sys, {2, 2}, {1, 1})
	compute_layout_all(&sys)
	wa := get_quad2d(&sys, a)
	wb := get_quad2d(&sys, b)
	testing.expect(t, wa.world_position == wa.position, "orphan a layout self")
	testing.expect(t, wb.world_position == wb.position, "orphan b layout self")
}

// ---------------------------------------------------------------
// Hit testing ---------------------------------------------------
// ---------------------------------------------------------------

@(test)
test_point_in_widget_quad_box :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 4)
	defer shutdown(&sys)

	h, _ := create_quad2d(&sys, {10, 10}, {20, 20})
	q := get_widget(&sys, UIWidgetHandle(h))
	testing.expect(t, point_in_widget(q, {15, 15}), "inside hits")
	testing.expect(t, point_in_widget(q, {10, 10}), "top-left edge hits")
	testing.expect(t, point_in_widget(q, {30, 30}), "bot-right edge hits")
	testing.expect(t, !point_in_widget(q, {5, 5}), "outside misses")
	testing.expect(t, !point_in_widget(q, {31, 15}), "right of bbox misses")
}

@(test)
test_pick_widget_picks_top_z :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 8)
	defer shutdown(&sys)

	low, _ := create_quad2d(&sys, {0, 0}, {100, 100}, {}, {255, 255, 255, 255}, 0)
	high, _ := create_quad2d(&sys, {10, 10}, {20, 20}, {}, {255, 255, 255, 255}, 5)
	compute_layout_all(&sys)

	got := pick_widget(&sys, {15, 15})
	picked, has := got.?
	testing.expect(t, has && picked == UIWidgetHandle(high), "should pick top-z widget")

	got2 := pick_widget(&sys, {50, 50})
	picked2, has2 := got2.?
	testing.expect(t, has2 && picked2 == UIWidgetHandle(low), "fallback to lower-z widget")

	got3 := pick_widget(&sys, {500, 500})
	_, has3 := got3.?
	testing.expect(t, !has3, "no hit returns empty")
}

@(test)
test_pick_widget_skips_invisible :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 4)
	defer shutdown(&sys)
	h, _ := create_quad2d(&sys, {0, 0}, {10, 10})
	set_visible(get_widget(&sys, UIWidgetHandle(h)), false)
	got := pick_widget(&sys, {5, 5})
	_, has := got.?
	testing.expect(t, !has, "invisible widget not picked")
}

// ---------------------------------------------------------------
// Event dispatch ------------------------------------------------
// ---------------------------------------------------------------

@(thread_local)
mouse_calls: int

@(thread_local)
key_calls: int

mouse_handler :: proc(event: MouseEvent) {
	mouse_calls += 1
}

key_handler :: proc(event: KeyEvent) {
	key_calls += 1
}

@(test)
test_dispatch_mouse_bubbles_to_parent :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 8)
	defer shutdown(&sys)

	parent, _ := create_box(&sys, {0, 0}, {100, 100})
	child, _ := create_quad2d(&sys, {10, 10}, {20, 20})
	box_add_child(&sys, parent, UIWidgetHandle(child))

	mouse_calls = 0
	set_event_handler(get_widget(&sys, UIWidgetHandle(parent)), {on_mouse_down = mouse_handler})
	set_event_handler(get_widget(&sys, UIWidgetHandle(child)), {on_mouse_down = mouse_handler})

	dispatch_mouse_event(&sys, UIWidgetHandle(child),
		MouseEvent{type = .CLICK_DOWN, position = {15, 15}, button = 0, widget = UIWidgetHandle(child)},
		bubble = true)
	testing.expectf(t, mouse_calls == 2, "child + parent should fire, got %d", mouse_calls)

	mouse_calls = 0
	dispatch_mouse_event(&sys, UIWidgetHandle(child),
		MouseEvent{type = .CLICK_DOWN, position = {15, 15}, button = 0, widget = UIWidgetHandle(child)},
		bubble = false)
	testing.expectf(t, mouse_calls == 1, "no bubble: child only, got %d", mouse_calls)
}

@(test)
test_dispatch_key_only_matched_handler :: proc(t: ^testing.T) {
	sys: System
	init(&sys, 4)
	defer shutdown(&sys)

	h, _ := create_quad2d(&sys, {0, 0}, {1, 1})
	key_calls = 0
	set_event_handler(get_widget(&sys, UIWidgetHandle(h)), {on_key_down = key_handler})

	dispatch_key_event(&sys, UIWidgetHandle(h),
		KeyEvent{type = .KEY_UP, key = 32, widget = UIWidgetHandle(h)})
	testing.expect(t, key_calls == 0, "KEY_UP should not call on_key_down")

	dispatch_key_event(&sys, UIWidgetHandle(h),
		KeyEvent{type = .KEY_DOWN, key = 32, widget = UIWidgetHandle(h)})
	testing.expect(t, key_calls == 1, "KEY_DOWN should call once")
}

// ---------------------------------------------------------------
// Benchmarks: layout walk + pick scan ---------------------------
// ---------------------------------------------------------------

bench_ui_state :: struct {
	sys:  System,
	root: BoxHandle,
	hits: int,
}

build_subtree :: proc(sys: ^System, parent: BoxHandle, depth: int, branch: int) {
	if depth == 0 do return
	for _ in 0 ..< branch {
		c, _ := create_box(sys, {1, 1}, {10, 10})
		box_add_child(sys, parent, UIWidgetHandle(c))
		build_subtree(sys, c, depth - 1, branch)
	}
}

@(test)
bench_compute_layout_deep_tree :: proc(t: ^testing.T) {
	state: bench_ui_state
	opts := time.Benchmark_Options {
		rounds   = 5000,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_ui_state)opts.user_data
			init(&s.sys, 4096)
			s.root, _ = create_box(&s.sys, {0, 0}, {1000, 1000})
			build_subtree(&s.sys, s.root, 4, 4)
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_ui_state)opts.user_data
			for _ in 0 ..< opts.rounds {
				compute_layout(&s.sys, UIWidgetHandle(s.root))
			}
			opts.count = opts.rounds
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_ui_state)opts.user_data
			shutdown(&s.sys)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay, "bench failed")
	log.infof("compute_layout %d rounds in %v, %.0f rounds/sec",
		opts.rounds, opts.duration, opts.rounds_per_second)
}

@(test)
bench_pick_widget_many :: proc(t: ^testing.T) {
	state: bench_ui_state
	opts := time.Benchmark_Options {
		rounds   = 2000,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_ui_state)opts.user_data
			init(&s.sys, 1024)
			for i in 0 ..< 512 {
				x := f32((i * 13) % 800)
				y := f32((i * 7) % 600)
				create_quad2d(&s.sys, {x, y}, {16, 16}, {}, {255, 255, 255, 255}, i32(i % 10))
			}
			compute_layout_all(&s.sys)
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_ui_state)opts.user_data
			for k in 0 ..< opts.rounds {
				px := f32((k * 17) % 800)
				py := f32((k * 11) % 600)
				got := pick_widget(&s.sys, {px, py})
				if _, ok := got.?; ok do s.hits += 1
			}
			opts.count = opts.rounds
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_ui_state)opts.user_data
			shutdown(&s.sys)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay && state.hits > 0, "bench failed")
	log.infof("pick_widget %d rounds in %v, %.0f rounds/sec (hits=%d)",
		opts.rounds, opts.duration, opts.rounds_per_second, state.hits)
}
