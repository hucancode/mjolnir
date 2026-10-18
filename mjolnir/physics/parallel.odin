#+private
package physics

import "../geometry"
import "base:intrinsics"
import "core:thread"

@(private)
PARALLEL_MIN_ITEMS :: 100

@(private)
pool_wait :: proc(pool: ^thread.Pool) {
  for {
    task, ok := thread.pool_pop_waiting(pool)
    if !ok do break
    thread.pool_do_work(pool, task)
  }
  for thread.pool_num_outstanding(pool) > 0 {
    intrinsics.cpu_relax()
  }
}

// RangeProc handles items [start, end) of chunk `task`, which indexes per-task output slots.
@(private)
RangeProc :: #type proc(world: ^World, ctx: rawptr, task, start, end: int)

@(private = "file")
RangeTask :: struct {
  world: ^World,
  ctx:   rawptr,
  fn:    RangeProc,
  task:  int,
  start: int,
  end:   int,
}

// Splits n items into thread_count chunks on the pool, or runs them inline as
// task 0 when the work is small or the world is single-threaded. Tasks run
// with the caller's context.allocator, which must be thread-safe; worker
// temp allocators are never freed, so tasks must not use them.
@(private)
parallel_for :: proc(world: ^World, n: int, ctx: rawptr, fn: RangeProc, min_items := PARALLEL_MIN_ITEMS) {
  if n <= 0 do return
  threads := world.thread_count
  if threads <= 1 || n < min_items {
    fn(world, ctx, 0, 0, n)
    return
  }
  chunk := (n + threads - 1) / threads
  tasks := make([]RangeTask, threads, context.temp_allocator)
  for i in 0 ..< threads {
    start := i * chunk
    if start >= n do break
    tasks[i] = {world, ctx, fn, i, start, min(start + chunk, n)}
    thread.pool_add_task(&world.thread_pool, context.allocator, proc(t: thread.Task) {
      d := (^RangeTask)(t.data)
      d.fn(d.world, d.ctx, d.task, d.start, d.end)
    }, &tasks[i], i)
  }
  pool_wait(&world.thread_pool)
}

bvh_refit :: proc(world: ^World) {
  parallel_for(world, len(world.dynamic_bvh.primitives), nil, proc(world: ^World, _: rawptr, _, start, end: int) {
    #no_bounds_check for i in start ..< end {
      body := lookup(world, world.dynamic_bvh.primitives[i]) or_continue
      if body.is_sleeping do continue
      world.dynamic_bvh.bounds[i] = fat_aabb(body)
    }
  })
  geometry.bvh_refit(&world.dynamic_bvh)
}

@(private)
fat_aabb :: #force_inline proc(body: ^Body) -> geometry.Aabb {
  return {min = body.cached_aabb.min - SPECULATIVE_DISTANCE, max = body.cached_aabb.max + SPECULATIVE_DISTANCE}
}
