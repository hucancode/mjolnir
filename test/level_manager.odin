package tests

import "core:testing"
import lm "../mjolnir/level_manager"

// Test helpers
Test_Context :: struct {
	setup_called:    bool,
	teardown_called: bool,
	finished_called: bool,
	setup_result:    bool,
	teardown_result: bool,
}

test_setup :: proc(user_data: rawptr) -> bool {
	ctx := cast(^Test_Context)user_data
	ctx.setup_called = true
	return ctx.setup_result
}

test_teardown :: proc(user_data: rawptr) -> bool {
	ctx := cast(^Test_Context)user_data
	ctx.teardown_called = true
	return ctx.teardown_result
}

test_finished :: proc(user_data: rawptr) {
	ctx := cast(^Test_Context)user_data
	ctx.finished_called = true
}

@(test)
test_init :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	lm.init(&manager)
	testing.expect(
		t,
		manager.state == .Idle,
		"Initial state should be Idle",
	)
	_, ok := lm.get_current_level_id(&manager)
	testing.expect(
		t,
		!ok,
		"No current level initially",
	)
}

@(test)
test_load_level_creates_pending :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = true
	ctx.teardown_result = true

	lm.init(&manager)

	descriptor := lm.Level_Descriptor {
		id        = "Test Level",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	lm.load_level(&manager, descriptor)

	pending, ok := manager.pending.?
	testing.expect(t, ok, "Pending transition should be set")
	testing.expect(
		t,
		pending.descriptor.id == "Test Level",
		"Pending descriptor id should match",
	)
	testing.expect(
		t,
		manager.state == .Idle,
		"State should still be Idle before update",
	)
}

@(test)
test_blocking_traditional_transition_no_previous_level :: proc(
	t: ^testing.T,
) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = true
	ctx.teardown_result = true

	lm.init(&manager)

	descriptor := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	lm.load_level(&manager, descriptor, .Traditional, false)

	// First update: process pending, start setup
	lm.update(&manager)
	testing.expect(
		t,
		manager.state == .Setting_Up,
		"Should be in Setting_Up state",
	)
	testing.expect(
		t,
		ctx.setup_called,
		"Setup should be called immediately (blocking)",
	)
	testing.expect(
		t,
		manager.setup_complete,
		"Setup should be complete (blocking)",
	)

	// Second update: finish setup
	lm.update(&manager)
	testing.expect(
		t,
		manager.state == .Setup_Complete,
		"Should be in Setup_Complete state",
	)

	// Third update: activate level
	lm.update(&manager)
	testing.expect(t, manager.state == .Idle, "Should return to Idle state")
	current_id, ok := lm.get_current_level_id(&manager)
	testing.expect(t, ok, "Should have current level")
	testing.expect(
		t,
		current_id == "Level 1",
		"Current level should be Level 1",
	)
}

@(test)
test_blocking_traditional_transition_with_previous_level :: proc(
	t: ^testing.T,
) {
	manager: lm.Level_Manager
	ctx1, ctx2: Test_Context
	ctx1.setup_result = true
	ctx1.teardown_result = true
	ctx2.setup_result = true
	ctx2.teardown_result = true

	lm.init(&manager)

	// Load first level
	desc1 := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx1,
	}
	lm.load_level(&manager, desc1, .Traditional, false)
	lm.update(&manager) // start setup
	lm.update(&manager) // finish setup
	lm.update(&manager) // activate

	testing.expect(t, manager.state == .Idle, "Should be Idle after level 1")
	testing.expect(t, ctx1.setup_called, "Level 1 setup should be called")

	// Load second level
	desc2 := lm.Level_Descriptor {
		id        = "Level 2",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx2,
	}
	lm.load_level(&manager, desc2, .Traditional, false)

	// First update: process pending, start teardown of level 1
	lm.update(&manager)
	testing.expect(
		t,
		manager.state == .Tearing_Down,
		"Should be in Tearing_Down state",
	)
	testing.expect(t, ctx1.teardown_called, "Level 1 teardown should be called")

	// Second update: finish teardown
	lm.update(&manager)
	testing.expect(
		t,
		manager.state == .Teardown_Complete,
		"Should be in Teardown_Complete state",
	)

	// Third update: start setup of level 2
	lm.update(&manager)
	testing.expect(
		t,
		manager.state == .Setting_Up,
		"Should be in Setting_Up state",
	)
	testing.expect(t, ctx2.setup_called, "Level 2 setup should be called")

	// Fourth update: finish setup
	lm.update(&manager)
	testing.expect(
		t,
		manager.state == .Setup_Complete,
		"Should be in Setup_Complete state",
	)

	// Fifth update: activate level 2
	lm.update(&manager)
	testing.expect(t, manager.state == .Idle, "Should return to Idle state")
	current_id, ok := lm.get_current_level_id(&manager)
	testing.expect(t, ok, "Should have current level")
	testing.expect(
		t,
		current_id == "Level 2",
		"Current level should be Level 2",
	)
}

@(test)
test_reject_load_while_transitioning :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx1, ctx2: Test_Context
	ctx1.setup_result = true
	ctx1.teardown_result = true
	ctx2.setup_result = true
	ctx2.teardown_result = true

	lm.init(&manager)

	desc1 := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx1,
	}
	lm.load_level(&manager, desc1, .Traditional, false)
	lm.update(&manager) // start setup

	testing.expect(
		t,
		manager.state == .Setting_Up,
		"Should be in Setting_Up state",
	)

	// Try to load another level while transitioning
	desc2 := lm.Level_Descriptor {
		id        = "Level 2",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx2,
	}
	lm.load_level(&manager, desc2, .Traditional, false)

	// Should not create pending
	_, ok := manager.pending.?
	testing.expect(t, !ok, "Should reject load while transitioning")
	testing.expect(t, !ctx2.setup_called, "Level 2 setup should not be called")
}

@(test)
test_on_finished_callback :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = true
	ctx.teardown_result = true

	lm.init(&manager)

	descriptor := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	lm.load_level(
		&manager,
		descriptor,
		.Traditional,
		false,
		test_finished,
		&ctx,
	)

	lm.update(&manager) // start setup
	lm.update(&manager) // finish setup
	lm.update(&manager) // activate

	testing.expect(
		t,
		ctx.finished_called,
		"Finished callback should be called on activation",
	)
}

@(test)
test_setup_failure_returns_to_idle :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = false // Setup will fail
	ctx.teardown_result = true

	lm.init(&manager)

	descriptor := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	lm.load_level(&manager, descriptor, .Traditional, false)

	lm.update(&manager) // start setup
	testing.expect(t, ctx.setup_called, "Setup should be called")
	testing.expect(t, manager.setup_complete, "Setup should be complete")
	testing.expect(t, !manager.setup_success, "Setup should fail")

	lm.update(&manager) // finish setup (with error)
	testing.expect(
		t,
		manager.state == .Idle,
		"Should return to Idle on setup failure",
	)
	_, ok := lm.get_current_level_id(&manager)
	testing.expect(
		t,
		!ok,
		"No level should be active",
	)
}

@(test)
test_show_loading_screen :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = true
	ctx.teardown_result = true

	lm.init(&manager)

	descriptor := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	// Request with loading screen
	lm.load_level(&manager, descriptor, .Traditional, true)

	testing.expect(
		t,
		!lm.should_show_loading(&manager),
		"Should not show loading before update",
	)

	lm.update(&manager) // start setup
	testing.expect(
		t,
		lm.should_show_loading(&manager),
		"Should show loading during setup",
	)

	lm.update(&manager) // finish setup
	testing.expect(
		t,
		lm.should_show_loading(&manager),
		"Should still show loading in Setup_Complete",
	)

	lm.update(&manager) // activate
	testing.expect(
		t,
		!lm.should_show_loading(&manager),
		"Should not show loading when Idle",
	)
}

@(test)
test_is_transitioning :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = true
	ctx.teardown_result = true

	lm.init(&manager)

	testing.expect(
		t,
		!lm.is_transitioning(&manager),
		"Should not be transitioning initially",
	)

	descriptor := lm.Level_Descriptor {
		id        = "Level 1",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	lm.load_level(&manager, descriptor, .Traditional, false)

	testing.expect(
		t,
		!lm.is_transitioning(&manager),
		"Should not be transitioning before update",
	)

	lm.update(&manager) // start setup
	testing.expect(
		t,
		lm.is_transitioning(&manager),
		"Should be transitioning during setup",
	)

	lm.update(&manager) // finish setup
	testing.expect(
		t,
		lm.is_transitioning(&manager),
		"Should be transitioning in Setup_Complete",
	)

	lm.update(&manager) // activate
	testing.expect(
		t,
		!lm.is_transitioning(&manager),
		"Should not be transitioning after activation",
	)
}

@(test)
test_reject_loading_same_level :: proc(t: ^testing.T) {
	manager: lm.Level_Manager
	ctx: Test_Context
	ctx.setup_result = true
	ctx.teardown_result = true

	lm.init(&manager)

	// Load Level 2
	descriptor := lm.Level_Descriptor {
		id        = "Level 2",
		setup     = test_setup,
		teardown  = test_teardown,
		user_data = &ctx,
	}

	lm.load_level(&manager, descriptor, .Traditional, false)
	lm.update(&manager) // start setup
	lm.update(&manager) // finish setup
	lm.update(&manager) // activate

	testing.expect(t, manager.state == .Idle, "Should be Idle after loading")
	current_id, id_ok := lm.get_current_level_id(&manager)
	testing.expect(t, id_ok, "Should have current level")
	testing.expect(
		t,
		current_id == "Level 2",
		"Should be in Level 2",
	)

	// Reset context flags
	ctx.setup_called = false
	ctx.teardown_called = false

	// Try to load Level 2 again
	lm.load_level(&manager, descriptor, .Traditional, false)

	// Should reject the request
	_, ok := manager.pending.?
	testing.expect(
		t,
		!ok,
		"Should not create pending transition for same level",
	)

	// Update should not trigger any transitions
	lm.update(&manager)
	testing.expect(t, manager.state == .Idle, "Should remain Idle")
	testing.expect(
		t,
		!ctx.setup_called,
		"Setup should not be called again",
	)
	testing.expect(
		t,
		!ctx.teardown_called,
		"Teardown should not be called",
	)
	current_id2, ok2 := lm.get_current_level_id(&manager)
	testing.expect(t, ok2, "Should still have current level")
	testing.expect(
		t,
		current_id2 == "Level 2",
		"Should still be in Level 2",
	)
}
