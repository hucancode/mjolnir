package mjolnir

import "core:log"
import "core:thread"
import "core:time"
import "platform"

// RENDER_FPS is the target frame rate of Loop.frame (-define:RENDER_FPS=n).
RENDER_FPS :: #config(RENDER_FPS, 60)
@(private = "file")
FRAME_TIME :: 1.0 / RENDER_FPS
@(private = "file")
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
// UPDATE_FPS is the tick rate of Loop.update (-define:UPDATE_FPS=n, default RENDER_FPS).
UPDATE_FPS :: #config(UPDATE_FPS, RENDER_FPS)
@(private = "file")
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
@(private = "file")
UPDATE_FRAME_TIME_MILIS :: UPDATE_FRAME_TIME * 1_000.0
@(private = "file")
MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED :: 20
// USE_PARALLEL_UPDATE runs Loop.update on its own thread (-define:USE_PARALLEL_UPDATE=true).
USE_PARALLEL_UPDATE :: #config(USE_PARALLEL_UPDATE, false)
#assert(ODIN_OS != .JS || !USE_PARALLEL_UPDATE, "no threads on the web")
// FRAME_LIMIT stops run after this many frames; 0 means no limit (-define:FRAME_LIMIT=n).
FRAME_LIMIT :: #config(FRAME_LIMIT, 0)

// Setup is what Loop.setup reports: WAIT to be called again next iteration (render is not
// ready yet), READY to start the loop, FAIL to stop it.
Setup :: enum {
  WAIT,
  READY,
  FAIL,
}

// Loop holds the application callbacks run drives; it knows nothing else.
Loop :: struct($T: typeid) {
  app:          ^T,
  should_close: proc(app: ^T) -> bool, // polled once per iteration, main thread
  // UPDATE_FPS ticks, on its own thread with USE_PARALLEL_UPDATE: read input and make every
  // edit here, under render.lock
  update:       proc(app: ^T, dt: f32),
  frame:        proc(app: ^T) -> bool, // RENDER_FPS, main thread: only poll events and render; false on error
  // optional, main thread: called each iteration until it returns READY, before the first
  // update (wait for render.ready, build the scene); FAIL stops the loop. shutdown runs once
  // after the last iteration
  setup:        proc(app: ^T) -> Setup,
  shutdown:     proc(app: ^T),
}

// run drives loop until should_close, setup fails, FRAME_LIMIT frames, or too many
// consecutive frame failures, then calls shutdown. Natively it returns then, on the calling
// thread (the one that created the window); on the web it returns at once and the browser
// calls step each animation frame.
run :: proc(loop: Loop($T)) {
  runner = {loop = transmute(Loop(byte))loop}
  platform.run(advance)
}

@(private = "file")
Runner :: struct {
  loop:        Loop(byte),
  last_update: time.Time,
  last_frame:  time.Time,
  frame:       int,
  error_count: int,
  // setup returned READY
  started:     bool,
  // the update thread runs ticks while true
  active:      bool,
  thread:      ^thread.Thread,
}

// The loop run drives; it outlives run on the web.
@(private = "file")
runner: Runner

// One iteration of the loop, stopping it once over; false then.
@(private = "file")
advance :: proc() -> bool {
  if step(&runner) do return true
  stop(&runner)
  return false
}

// One iteration of the loop; false when it is over. Sleeps until the next frame.
@(private = "file")
step :: proc(r: ^Runner) -> bool {
  loop := &r.loop
  if loop.should_close(loop.app) do return false
  if !r.started {
    if loop.setup != nil {
      switch loop.setup(loop.app) {
      case .WAIT:
        return true
      case .FAIL:
        log.error("Setup failed, exiting...")
        return false
      case .READY:
      }
    }
    r.started = true
    r.last_update = time.now()
    when USE_PARALLEL_UPDATE {
      r.active = true
      r.thread = thread.create(update_thread_proc)
      r.thread.data = r
      r.thread.init_context = context
      thread.start(r.thread)
    }
  }
  when !USE_PARALLEL_UPDATE {
    tick(r)
  }
  remaining := FRAME_TIME_MILIS - time.duration_milliseconds(time.since(r.last_frame))
  if remaining > 0 {
    // Don't oversleep past the next update tick (UPDATE_FPS may exceed
    // RENDER_FPS); keep input latency bounded to one tick.
    when !USE_PARALLEL_UPDATE {
      until_tick := UPDATE_FRAME_TIME_MILIS - time.duration_milliseconds(time.since(r.last_update))
      if until_tick < remaining do remaining = until_tick
    }
    if remaining > 0.2 do platform.sleep(remaining)
    return true
  }
  r.last_frame = time.now()
  ok := loop.frame(loop.app)
  free_all(context.temp_allocator)
  if ok {
    r.error_count = 0
  } else {
    r.error_count += 1
    if r.error_count >= MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED {
      log.errorf("Too many render errors, exiting...")
      return false
    }
  }
  r.frame += 1
  when FRAME_LIMIT > 0 {
    if r.frame >= FRAME_LIMIT {
      log.infof("Reached frame limit %d, exiting gracefully", FRAME_LIMIT)
      return false
    }
  }
  return true
}

// Stops the update thread and shuts the app down.
@(private = "file")
stop :: proc(r: ^Runner) {
  when USE_PARALLEL_UPDATE {
    if r.thread != nil {
      r.active = false
      thread.join(r.thread)
      thread.destroy(r.thread)
    }
  }
  if r.loop.shutdown != nil do r.loop.shutdown(r.loop.app)
}

// tick runs one update when due; false when it was not.
@(private = "file")
tick :: proc(r: ^Runner) -> bool {
  dt := f32(time.duration_seconds(time.since(r.last_update)))
  if dt < UPDATE_FRAME_TIME do return false
  r.last_update = time.now()
  r.loop.update(r.loop.app, dt)
  return true
}

@(private = "file")
update_thread_proc :: proc(t: ^thread.Thread) {
  r := cast(^Runner)t.data
  for r.active {
    if !tick(r) do time.sleep(time.Millisecond * 2)
    free_all(context.temp_allocator)
  }
  log.info("Update thread terminating")
}
