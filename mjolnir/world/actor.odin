package world

import cont "../containers"
import "core:log"
import "core:slice"

Actor :: struct($T: typeid) {
  node_handle:  NodeHandle,
  data:         T,
  tick_proc:    proc(actor: ^Actor(T), ctx: ^ActorContext, dt: f32),
  tick_enabled: bool,
}

ActorHandle :: distinct cont.Handle

ActorPool :: struct($T: typeid) {
  actors:    Pool(Actor(T)),
  tick_list: [dynamic]ActorHandle,
}

ActorContext :: struct {
  world:      ^World,
  delta_time: f32,
  game_state: rawptr,
}

actor_pool_init :: proc(pool: ^ActorPool($T), capacity: u32 = 0) {
  cont.init(&pool.actors, capacity)
}

actor_pool_destroy :: proc(pool: ^ActorPool($T)) {
  cont.destroy(pool.actors, proc(actor: ^Actor(T)) {})
  delete(pool.tick_list)
}

actor_alloc :: proc(
  pool: ^ActorPool($T),
  node_handle: NodeHandle,
) -> (
  handle: ActorHandle,
  ok: bool,
) {
  actor : ^Actor(T)
  handle, actor = cont.alloc(&pool.actors, ActorHandle) or_return
  actor.node_handle = node_handle
  return handle, true
}

actor_free :: proc(
  pool: ^ActorPool($T),
  handle: ActorHandle,
) -> (
  actor: ^Actor(T),
  freed: bool,
) #optional_ok {
  actor = cont.free(&pool.actors, handle) or_return
  if actor.tick_enabled {
    if i, found := slice.linear_search(pool.tick_list[:], handle); found {
        unordered_remove(&pool.tick_list, i)
    }
  }
  return actor, true
}

actor_get :: proc(
  pool: ^ActorPool($T),
  handle: ActorHandle,
) -> (
  actor: ^Actor(T),
  ok: bool,
) #optional_ok {
  return cont.get(pool.actors, handle)
}

actor_enable_tick :: proc(pool: ^ActorPool($T), handle: ActorHandle) {
  actor, ok := cont.get(pool.actors, handle)
  if !ok do return
  if !actor.tick_enabled {
    actor.tick_enabled = true
    append(&pool.tick_list, handle)
  }
}

actor_disable_tick :: proc(pool: ^ActorPool($T), handle: ActorHandle) {
  actor, ok := cont.get(pool.actors, handle)
  if !ok do return
  if actor.tick_enabled {
    actor.tick_enabled = false
    for i := 0; i < len(pool.tick_list); i += 1 {
      if pool.tick_list[i] == handle {
        unordered_remove(&pool.tick_list, i)
        break
      }
    }
  }
}

actor_pool_tick :: proc(pool: ^ActorPool($T), ctx: ^ActorContext) {
  for i := 0; i < len(pool.tick_list); i += 1 {
    handle := pool.tick_list[i]
    actor, ok := cont.get(pool.actors, handle)
    if !ok {
      unordered_remove(&pool.tick_list, i)
      i -= 1
      continue
    }
    if actor.tick_proc != nil && actor.tick_enabled {
      actor.tick_proc(actor, ctx, ctx.delta_time)
    }
  }
}

ActorPoolEntry :: struct {
  pool_ptr:   rawptr,
  tick_fn:    proc(pool_ptr: rawptr, ctx: ^ActorContext),
  alloc_fn:   proc(
    pool_ptr: rawptr,
    node_handle: NodeHandle,
  ) -> (
    ActorHandle,
    bool,
  ),
  get_fn:     proc(
    pool_ptr: rawptr,
    handle: ActorHandle,
  ) -> (
    rawptr,
    bool,
  ),
  free_fn:    proc(pool_ptr: rawptr, handle: ActorHandle) -> bool,
  destroy_fn: proc(pool_ptr: rawptr),
}
