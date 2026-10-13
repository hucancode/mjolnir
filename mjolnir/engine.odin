package mjolnir

import "core:log"
import "core:thread"
import "core:time"

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
// FRAME_LIMIT stops run after this many frames; 0 means no limit (-define:FRAME_LIMIT=n).
FRAME_LIMIT :: #config(FRAME_LIMIT, 0)

// Loop holds the application callbacks run drives; it knows nothing else.
Loop :: struct($T: typeid) {
  app:          ^T,
  should_close: proc(app: ^T) -> bool, // polled once per iteration, main thread
  update:       proc(app: ^T, dt: f32), // UPDATE_FPS ticks; own thread with USE_PARALLEL_UPDATE
  frame:        proc(app: ^T) -> bool, // RENDER_FPS, main thread: poll events, render; false on error
}

// run drives loop on the calling thread (the one that created the window)
// until should_close, FRAME_LIMIT frames, or too many consecutive frame failures.
run :: proc(loop: Loop($T)) {
  run_loop(transmute(Loop(byte))loop)
}

@(private = "file")
Ticker :: struct {
  loop:        Loop(byte),
  last_update: time.Time,
  active:      bool,
}

@(private = "file")
run_loop :: proc(loop: Loop(byte)) {
  ticker := Ticker{loop = loop, last_update = time.now(), active = true}
  when USE_PARALLEL_UPDATE {
    update_thread := thread.create(update_thread_proc)
    update_thread.data = &ticker
    update_thread.init_context = context
    thread.start(update_thread)
    defer {
      ticker.active = false
      thread.join(update_thread)
      thread.destroy(update_thread)
    }
  }
  last_frame: time.Time
  frame := 0
  error_count := 0
  for !loop.should_close(loop.app) {
    when !USE_PARALLEL_UPDATE {
      tick(&ticker)
    }
    remaining := FRAME_TIME_MILIS - time.duration_milliseconds(time.since(last_frame))
    if remaining > 0 {
      // Don't oversleep past the next update tick (UPDATE_FPS may exceed
      // RENDER_FPS); keep input latency bounded to one tick.
      when !USE_PARALLEL_UPDATE {
        until_tick := UPDATE_FRAME_TIME_MILIS - time.duration_milliseconds(time.since(ticker.last_update))
        if until_tick < remaining do remaining = until_tick
      }
      if remaining > 0.2 {
        time.sleep(time.Duration(remaining * f64(time.Millisecond)))
      }
      continue
    }
    last_frame = time.now()
    ok := loop.frame(loop.app)
    free_all(context.temp_allocator)
    if ok {
      error_count = 0
    } else {
      error_count += 1
      if error_count >= MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED {
        log.errorf("Too many render errors, exiting...")
        break
      }
    }
    frame += 1
    when FRAME_LIMIT > 0 {
      if frame >= FRAME_LIMIT {
        log.infof("Reached frame limit %d, exiting gracefully", FRAME_LIMIT)
        break
      }
    }
  }
}

// tick runs one update when due; false when it was not.
@(private = "file")
tick :: proc(self: ^Ticker) -> bool {
  dt := f32(time.duration_seconds(time.since(self.last_update)))
  if dt < UPDATE_FRAME_TIME do return false
  self.last_update = time.now()
  self.loop.update(self.loop.app, dt)
  return true
}

@(private = "file")
update_thread_proc :: proc(t: ^thread.Thread) {
  ticker := cast(^Ticker)t.data
  for ticker.active {
    if !tick(ticker) do time.sleep(time.Millisecond * 2)
    free_all(context.temp_allocator)
  }
  log.info("Update thread terminating")
}
