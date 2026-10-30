package mjolnir

import "core:log"
import "core:thread"
import "core:time"
import "platform"

// RENDER_FPS is the target frame rate of Loop.render (-define:RENDER_FPS=n).
RENDER_FPS :: #config(RENDER_FPS, 60)
@(private = "file")
FRAME_TIME :: 1.0 / RENDER_FPS
@(private = "file")
FRAME_TIME_MILLIS :: FRAME_TIME * 1_000.0
// UPDATE_FPS is the tick rate of Loop.update (-define:UPDATE_FPS=n, default RENDER_FPS).
UPDATE_FPS :: #config(UPDATE_FPS, RENDER_FPS)
@(private = "file")
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
@(private = "file")
UPDATE_FRAME_TIME_MILLIS :: UPDATE_FRAME_TIME * 1_000.0
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

// Loop holds the application callbacks run paces; it knows nothing else.
Loop :: struct($T: typeid) {
  app:      ^T,
  // optional, main thread: called each iteration until it returns READY, before the first
  // update (wait for render.ready, build the scene); FAIL stops the loop
  setup:    proc(app: ^T) -> Setup,
  // UPDATE_FPS ticks, on its own thread with USE_PARALLEL_UPDATE: read input and make every
  // edit here, under render.lock
  update:   proc(app: ^T, dt: f32),
  // RENDER_FPS, main thread: poll events and render (mjolnir.frame); false ends the loop
  render:   proc(app: ^T) -> bool,
  // optional: runs once after the last iteration
  shutdown: proc(app: ^T),
}

// run drives loop until render returns false, setup fails or FRAME_LIMIT frames, then calls
// shutdown. Natively it returns then, on the calling thread (the one that created the window);
// on the web it returns at once and the browser calls step each animation frame.
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
  if !r.started {
    if loop.setup != nil {
      switch loop.setup(loop.app) {
      case .WAIT:
        return true
      case .FAIL:
        log.error("Setup failed, exiting...")
        platform.fail()
        return false
      case .READY:
      }
    }
    r.started = true
    platform.ready()
    // due at once: the first frame draws what an update placed
    r.last_update = time.time_add(time.now(), -time.Second / UPDATE_FPS)
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
  remaining := FRAME_TIME_MILLIS - time.duration_milliseconds(time.since(r.last_frame))
  if remaining > 0 {
    // Don't oversleep past the next update tick (UPDATE_FPS may exceed
    // RENDER_FPS); keep input latency bounded to one tick.
    when !USE_PARALLEL_UPDATE {
      until_tick := UPDATE_FRAME_TIME_MILLIS - time.duration_milliseconds(time.since(r.last_update))
      if until_tick < remaining do remaining = until_tick
    }
    if remaining > 0.2 do platform.sleep(remaining)
    return true
  }
  r.last_frame = time.now()
  running := loop.render(loop.app)
  free_all(context.temp_allocator)
  if !running do return false
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
  // a frame dump (render.FRAME_DUMP) is slower than real time: steps are fixed so it plays right
  when #config(FRAME_DUMP, "") != "" {
    dt = UPDATE_FRAME_TIME
  }
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
