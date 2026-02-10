package world

import "core:testing"
import "core:time"

TestPlayerData2 :: struct {
  health:        f32,
  speed:         f32,
  ticks_elapsed: u32,
}

TestMobData2 :: struct {
  ai_state:      AIState2,
  ticks_elapsed: u32,
}

AIState2 :: enum {
  IDLE,
  CHASING,
  ATTACKING,
}

player_tick2 :: proc(
  actor: ^Actor(TestPlayerData2),
  ctx: ^ActorContext,
  dt: f32,
) {
  actor.data.ticks_elapsed += 1
  actor.data.health = min(100, actor.data.health + dt * 5)
}

mob_tick2 :: proc(
  actor: ^Actor(TestMobData2),
  ctx: ^ActorContext,
  dt: f32,
) {
  actor.data.ticks_elapsed += 1
  if actor.data.ai_state == .IDLE {
    actor.data.ai_state = .CHASING
  }
}

@(test)
test_spawn_and_get_actor :: proc(t: ^testing.T) {
  w: World
  init(&w)
	defer shutdown(&w)
  actor_handle, ok := spawn_actor(&w, TestPlayerData2)
  testing.expect(t, ok)
  actor := get_actor(&w, TestPlayerData2, actor_handle)
  actor.data = TestPlayerData2 {
    health = 100,
    speed  = 5,
  }
  freed := free_actor(&w, TestPlayerData2, actor_handle)
  testing.expect(t, freed)
}

@(test)
test_auto_tick_actors :: proc(t: ^testing.T) {
  w: World
  init(&w)
	defer shutdown(&w)
  player_handle := spawn_actor(&w, TestPlayerData2)
  player := get_actor(&w, TestPlayerData2, player_handle)
  player.data = TestPlayerData2 {
    health = 50,
    speed  = 5,
  }
  player.tick_proc = player_tick2
  enable_actor_tick(&w, TestPlayerData2, player_handle)
  mob_handle := spawn_actor(&w, TestMobData2)
  mob := get_actor(&w, TestMobData2, mob_handle)
  mob.data = TestMobData2 {
    ai_state = .IDLE,
  }
  mob.tick_proc = mob_tick2
  enable_actor_tick(&w, TestMobData2, mob_handle)
  testing.expect(t, player.data.ticks_elapsed == 0)
  testing.expect(t, mob.data.ticks_elapsed == 0)
  world_tick_actors(&w, 0.016)
  testing.expect(t, player.data.ticks_elapsed == 1)
  testing.expect(t, mob.data.ticks_elapsed == 1)
  testing.expect(t, mob.data.ai_state == .CHASING)
  world_tick_actors(&w, 0.016)
  testing.expect(t, player.data.ticks_elapsed == 2)
  testing.expect(t, mob.data.ticks_elapsed == 2)
}

@(test)
test_lazy_pool_creation :: proc(t: ^testing.T) {
  w: World
  init(&w)
	defer shutdown(&w)
  testing.expect(t, len(w.actor_pools) == 0)
  _, ok1 := spawn_actor(&w, TestPlayerData2)
  testing.expect(t, ok1)
  testing.expect(t, len(w.actor_pools) == 1)
  _, ok2 := spawn_actor(&w, TestMobData2)
  testing.expect(t, ok2)
  testing.expect(t, len(w.actor_pools) == 2)
  _, ok3 := spawn_actor(&w, TestPlayerData2)
  testing.expect(t, ok3)
  testing.expect(t, len(w.actor_pools) == 2, "Should reuse existing pool")
}

GameState :: struct {
  score:          int,
  enemies_killed: int,
  wave_number:    int,
}

EnemyData :: struct {
  health:        f32,
  reward_points: int,
}

enemy_tick :: proc(
  actor: ^Actor(EnemyData),
  ctx: ^ActorContext,
  dt: f32,
) {
  game := cast(^GameState)ctx.game_state
  if game == nil do return
  // Simulate enemy death
  if actor.data.health <= 0 {
    game.score += actor.data.reward_points
    game.enemies_killed += 1
  }
}

@(test)
test_custom_game_state :: proc(t: ^testing.T) {
  w: World
  init(&w)
	defer shutdown(&w)
  game := GameState {
    score          = 0,
    enemies_killed = 0,
    wave_number    = 1,
  }
  // Spawn enemy with dead health to trigger score update
  enemy_handle := spawn_actor(&w, EnemyData)
  enemy := get_actor(&w, EnemyData, enemy_handle)
  enemy.data = EnemyData {
    health        = 0,
    reward_points = 100,
  }
  enemy.tick_proc = enemy_tick
  enable_actor_tick(&w, EnemyData, enemy_handle)
  testing.expect(t, game.score == 0)
  testing.expect(t, game.enemies_killed == 0)
  // Tick with custom game state
  world_tick_actors(&w, 0.016, &game)
  testing.expect(t, game.score == 100, "Score should be updated")
  testing.expect(
    t,
    game.enemies_killed == 1,
    "Enemies killed should increment",
  )
}
