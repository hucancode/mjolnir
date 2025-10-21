package world

import "../resources"
import "core:log"

Actor :: struct($T: typeid) {
  node_handle:  resources.Handle,
  data:         T,
  tick_proc:    proc(actor: ^Actor(T), ctx: ^ActorContext, dt: f32),
  tick_enabled: bool,
}

ActorPool :: struct($T: typeid) {
  actors:    resources.Pool(Actor(T)),
  tick_list: [dynamic]resources.Handle,
}

ActorContext :: struct {
  world:      ^World,
  rm:         ^resources.Manager,
  delta_time: f32,
}

actor_pool_init :: proc(pool: ^ActorPool($T), capacity: u32 = 0) {
  resources.pool_init(&pool.actors, capacity)
  pool.tick_list = make([dynamic]resources.Handle, 0)
}

actor_pool_destroy :: proc(pool: ^ActorPool($T)) {
  resources.pool_destroy(pool.actors, proc(actor: ^Actor(T)) {})
  delete(pool.tick_list)
}

actor_alloc :: proc(
  pool: ^ActorPool($T),
  node_handle: resources.Handle,
) -> (
  handle: resources.Handle,
  actor: ^Actor(T),
  ok: bool,
) {
  handle, actor, ok = resources.alloc(&pool.actors)
  if !ok do return {}, nil, false

  actor.node_handle = node_handle
  actor.tick_enabled = false
  actor.tick_proc = nil

  return handle, actor, true
}

actor_free :: proc(
  pool: ^ActorPool($T),
  handle: resources.Handle,
) -> (
  actor: ^Actor(T),
  freed: bool,
) {
  actor, freed = resources.free(&pool.actors, handle)
  if !freed do return nil, false

  if actor.tick_enabled {
    for i := 0; i < len(pool.tick_list); i += 1 {
      if pool.tick_list[i] == handle {
        unordered_remove(&pool.tick_list, i)
        break
      }
    }
  }

  return actor, true
}

actor_get :: proc(
  pool: ^ActorPool($T),
  handle: resources.Handle,
) -> (
  actor: ^Actor(T),
  ok: bool,
) #optional_ok {
  return resources.get(pool.actors, handle)
}

actor_enable_tick :: proc(pool: ^ActorPool($T), handle: resources.Handle) {
  actor, ok := resources.get(pool.actors, handle)
  if !ok do return
  if !actor.tick_enabled {
    actor.tick_enabled = true
    append(&pool.tick_list, handle)
  }
}

actor_disable_tick :: proc(pool: ^ActorPool($T), handle: resources.Handle) {
  actor, ok := resources.get(pool.actors, handle)
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
    actor, ok := resources.get(pool.actors, handle)
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
    node_handle: resources.Handle,
  ) -> (
    resources.Handle,
    rawptr,
    bool,
  ),
  get_fn:     proc(
    pool_ptr: rawptr,
    handle: resources.Handle,
  ) -> (
    rawptr,
    bool,
  ),
  free_fn:    proc(pool_ptr: rawptr, handle: resources.Handle) -> bool,
  destroy_fn: proc(pool_ptr: rawptr),
}
