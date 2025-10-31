package level_manager

import "core:log"
import "core:thread"

// Level manager orchestrates async/blocking transitions between levels.
// It's a pure state machine - users provide callbacks that do actual work.
// Users manage their own engine/context pointers via user_data.

Level_Setup_Proc :: #type proc(user_data: rawptr) -> bool
Level_Teardown_Proc :: #type proc(user_data: rawptr) -> bool
Level_Finished_Proc :: #type proc(user_data: rawptr)

Setup_Mode :: enum {
  Blocking,
  Async,
}

Teardown_Mode :: enum {
  Blocking,
  Async,
}

Transition_Pattern :: enum {
  Seamless, // next setup async -> teleport -> previous teardown async (no loading screen)
  Traditional, // previous teardown -> next setup (with loading screen)
}

Level_State :: enum {
  Idle,
  Tearing_Down,
  Teardown_Complete,
  Setting_Up,
  Setup_Complete,
}

Level_Descriptor :: struct {
  id:        string,
  setup:     Level_Setup_Proc,
  teardown:  Level_Teardown_Proc,
  user_data: rawptr,
}

Pending_Transition :: struct {
  descriptor:    Level_Descriptor,
  pattern:       Transition_Pattern,
  show_loading:  bool,
  on_finished:   Level_Finished_Proc,
  callback_data: rawptr,
}

Level_Manager :: struct {
  current:             Maybe(Level_Descriptor),
  next:                Maybe(Level_Descriptor),
  pending:             Maybe(Pending_Transition),
  state:               Level_State,
  setup_thread:        ^thread.Thread,
  teardown_thread:     ^thread.Thread,
  setup_complete:      bool,
  teardown_complete:   bool,
  setup_success:       bool,
  teardown_success:    bool,
  pattern:             Transition_Pattern,
  setup_mode:          Setup_Mode,
  teardown_mode:       Teardown_Mode,
  show_loading:        bool,
  on_loading_finished: Level_Finished_Proc,
  callback_user_data:  rawptr,
}

Thread_Data :: struct {
  manager:    ^Level_Manager,
  descriptor: Level_Descriptor,
}

init :: proc(lm: ^Level_Manager) {
  lm.state = .Idle
  log.info("Level manager initialized")
}

shutdown :: proc(lm: ^Level_Manager) {
  if lm.setup_thread != nil {
    thread.destroy(lm.setup_thread)
    lm.setup_thread = nil
  }
  if lm.teardown_thread != nil {
    thread.destroy(lm.teardown_thread)
    lm.teardown_thread = nil
  }
  if current, ok := lm.current.?; ok {
    if lm.state == .Idle {
      log.info("Tearing down active level on shutdown:", current.id)
      current.teardown(current.user_data)
    }
  }
  lm^ = {}
  log.info("Level manager destroyed")
}

is_transitioning :: proc(lm: ^Level_Manager) -> bool {
  return(
    lm.state == .Tearing_Down ||
    lm.state == .Teardown_Complete ||
    lm.state == .Setting_Up ||
    lm.state == .Setup_Complete ||
    lm.teardown_thread != nil \
  )
}

should_show_loading :: proc(lm: ^Level_Manager) -> bool {
  return lm.show_loading && is_transitioning(lm)
}

get_current_level_id :: proc(lm: ^Level_Manager) -> (ret: string, ok: bool) {
  if current, ok := lm.current.?; ok {
    return current.id, true
  }
  return "", false
}

load_level :: proc(
  lm: ^Level_Manager,
  descriptor: Level_Descriptor,
  pattern: Transition_Pattern = .Traditional,
  show_loading_screen: bool = true,
  on_finished: Level_Finished_Proc = nil,
  callback_data: rawptr = nil,
) {
  if lm.state != .Idle {
    log.warn("Cannot load level while transition in progress")
    return
  }
  if lm.teardown_thread != nil {
    log.warn("Cannot load level while seamless teardown is still running")
    return
  }
  // Prevent async/seamless loading when user_data pointer matches current level
  // async loading must operate on 2 different levels (we can't transition to level 1 from level 1 itself, because setup are run before teardown)
  // block loading can operate on the same level (we can transition to level 1 from level 1 since teardown are run before setup)
  if pattern == .Seamless {
    if current, ok := lm.current.?; ok {
      if current.user_data == descriptor.user_data {
        log.warn("Cannot use seamless transition with same user_data pointer:", descriptor.id)
        log.warn("Use .Traditional pattern instead, or provide different user_data")
        return
      }
    }
  }
  lm.pending = Pending_Transition {
    descriptor    = descriptor,
    pattern       = pattern,
    show_loading  = show_loading_screen,
    on_finished   = on_finished,
    callback_data = callback_data,
  }
  log.info("Level transition requested:", descriptor.id)
}

update :: proc(lm: ^Level_Manager) {
  // Process pending transition request
  if pending, ok := lm.pending.?; ok {
    lm.pending = nil
    lm.next = pending.descriptor
    lm.pattern = pending.pattern
    lm.show_loading = pending.show_loading
    lm.on_loading_finished = pending.on_finished
    lm.callback_user_data = pending.callback_data
    switch pending.pattern {
    case .Seamless:
      lm.setup_mode = .Async
      lm.teardown_mode = .Async
      _start_seamless_transition(lm)
    case .Traditional:
      lm.setup_mode = .Blocking
      lm.teardown_mode = .Blocking
      _start_traditional_transition(lm)
    }
    return
  }

  // Check if seamless teardown thread completed (runs in background while Idle)
  if lm.state == .Idle && lm.teardown_thread != nil && lm.teardown_complete {
    log.info("Seamless teardown complete, cleaning up thread")
    thread_data := cast(^Thread_Data)lm.teardown_thread.data
    free(thread_data)
    thread.destroy(lm.teardown_thread)
    lm.teardown_thread = nil
  }

  switch lm.state {
  case .Idle:
  // no transition, nothing to do
  case .Tearing_Down:
    if lm.teardown_complete {
      _finish_teardown(lm)
      return
    }
  case .Teardown_Complete:
    _start_next_setup(lm)
    return
  case .Setting_Up:
    if lm.setup_complete {
      _finish_setup(lm)
      return
    }
  case .Setup_Complete:
    _activate_level(lm)
    return
  }
}

@(private)
_start_seamless_transition :: proc(lm: ^Level_Manager) {
  next := lm.next.? or_else panic("Next level not set")
  log.info("Starting seamless transition to:", next.id)
  lm.state = .Setting_Up
  lm.setup_complete = false
  lm.setup_success = false
  thread_data := new(Thread_Data)
  thread_data.manager = lm
  thread_data.descriptor = next
  setup_thread := thread.create(_async_setup_thread_proc)
  setup_thread.data = thread_data
  setup_thread.init_context = context
  thread.start(setup_thread)
  lm.setup_thread = setup_thread
}

@(private)
_start_traditional_transition :: proc(lm: ^Level_Manager) {
  if current, ok := lm.current.?; ok {
    log.info("Starting traditional transition: tearing down", current.id)
    lm.state = .Tearing_Down
    if lm.teardown_mode == .Blocking {
      lm.teardown_success = current.teardown(current.user_data)
      if !lm.teardown_success {
        log.warn("Level teardown failed:", current.id)
      }
      lm.teardown_complete = true
    } else {
      lm.teardown_complete = false
      lm.teardown_success = false
      thread_data := new(Thread_Data)
      thread_data.manager = lm
      thread_data.descriptor = current
      teardown_thread := thread.create(_async_teardown_thread_proc)
      teardown_thread.data = thread_data
      teardown_thread.init_context = context
      thread.start(teardown_thread)
      lm.teardown_thread = teardown_thread
    }
  } else {
    _start_next_setup(lm)
  }
}

@(private)
_start_next_setup :: proc(lm: ^Level_Manager) {
  next := lm.next.? or_else panic("Next level not set")
  lm.state = .Setting_Up
  if lm.setup_mode == .Blocking {
    lm.setup_success = next.setup(next.user_data)
    if !lm.setup_success {
      log.warn("Level setup failed:", next.id)
    }
    lm.setup_complete = true
  } else {
    lm.setup_complete = false
    lm.setup_success = false
    thread_data := new(Thread_Data)
    thread_data.manager = lm
    thread_data.descriptor = next
    setup_thread := thread.create(_async_setup_thread_proc)
    setup_thread.data = thread_data
    setup_thread.init_context = context
    thread.start(setup_thread)
    lm.setup_thread = setup_thread
  }
}

@(private)
_finish_teardown :: proc(lm: ^Level_Manager) {
  if lm.teardown_thread != nil {
    thread_data := cast(^Thread_Data)lm.teardown_thread.data
    free(thread_data)
    thread.destroy(lm.teardown_thread)
    lm.teardown_thread = nil
  }
  current := lm.current.? or_else panic("Current level not set")
  if !lm.teardown_success {
    log.warn("Level teardown completed with errors:", current.id)
  } else {
    log.info("Level teardown complete:", current.id)
  }
  lm.current = nil
  if lm.pattern == .Traditional {
    lm.state = .Teardown_Complete
  }
}

@(private)
_finish_setup :: proc(lm: ^Level_Manager) {
  if lm.setup_thread != nil {
    thread_data := cast(^Thread_Data)lm.setup_thread.data
    free(thread_data)
    thread.destroy(lm.setup_thread)
    lm.setup_thread = nil
  }
  next := lm.next.? or_else panic("Next level not set")
  if !lm.setup_success {
    log.warn("Level setup completed with errors:", next.id)
    lm.state = .Idle
    return
  }
  log.info("Level setup complete:", next.id)
  lm.state = .Setup_Complete
}

@(private)
_activate_level :: proc(lm: ^Level_Manager) {
  next := lm.next.? or_else panic("Next level not set")
  log.info("Activating level:", next.id)
  // Save old level descriptor BEFORE changing lm.current
  old_level: Maybe(Level_Descriptor)
  if lm.pattern == .Seamless {
    old_level = lm.current
  }
  lm.current = next
  lm.next = nil
  lm.state = .Idle
  if lm.on_loading_finished != nil {
    lm.on_loading_finished(lm.callback_user_data)
  }
  log.info("Level active:", next.id)
  // NOW start async teardown of old level (after activation)
  if old, ok := old_level.?; ok {
    log.info("Seamless transition: tearing down previous level:", old.id)
    lm.teardown_complete = false
    lm.teardown_success = false
    thread_data := new(Thread_Data)
    thread_data.manager = lm
    thread_data.descriptor = old
    teardown_thread := thread.create(_async_teardown_thread_proc)
    teardown_thread.data = thread_data
    teardown_thread.init_context = context
    thread.start(teardown_thread)
    lm.teardown_thread = teardown_thread
  }
}

@(private)
_async_setup_thread_proc :: proc(t: ^thread.Thread) {
  thread_data := cast(^Thread_Data)t.data
  descriptor := &thread_data.descriptor
  lm := thread_data.manager
  log.info("Async setup thread started:", descriptor.id)
  success := descriptor.setup(descriptor.user_data)
  lm.setup_success = success
  lm.setup_complete = true
  log.info(
    "Async setup thread finished:",
    descriptor.id,
    "success:",
    success,
  )
}

@(private)
_async_teardown_thread_proc :: proc(t: ^thread.Thread) {
  thread_data := cast(^Thread_Data)t.data
  descriptor := &thread_data.descriptor
  lm := thread_data.manager
  log.info("Async teardown thread started:", descriptor.id)
  success := descriptor.teardown(descriptor.user_data)
  lm.teardown_success = success
  lm.teardown_complete = true
  log.info(
    "Async teardown thread finished:",
    descriptor.id,
    "success:",
    success,
  )
}
