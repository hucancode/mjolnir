#+build !js
#+private file
package render

import "core:testing"

// Casters with descending scores, owners 1..n.
make_casters :: proc(n: int) -> (casters: [MAX_LIGHTS]Caster) {
	for i in 0 ..< n do casters[i] = {light = i, owner = u32(i) + 1, score = f32(n - i)}
	return
}

holds_map :: proc(maps: ^[MAX_SHADOW_MAPS]Caster, owner: u32) -> bool {
	for sm in maps do if sm.owner == owner do return true
	return false
}

@(test)
test_shadow_score_prefers_close_large_bright :: proc(t: ^testing.T) {
	cam := [3]f32{0, 0, 0}
	near := shadow_score({0, 0, 10, 2}, 1, cam)
	far := shadow_score({0, 0, 20, 2}, 1, cam)
	large := shadow_score({0, 0, 10, 4}, 1, cam)
	bright := shadow_score({0, 0, 10, 2}, 2, cam)
	inside := shadow_score({0, 0, 1, 2}, 1, cam)
	huge := shadow_score({0, 0, 100, 1000}, 1, cam)
	testing.expect(t, near > far, "closer light scores higher")
	testing.expect(t, large > near, "larger light scores higher")
	testing.expect(t, bright > near, "brighter light scores higher")
	testing.expect(t, inside > large, "camera inside the sphere scores highest")
	testing.expect(t, huge > inside, "a huge sphere around the camera scores higher")
	testing.expect(t, shadow_score({0, 0, 100, 1000}, 0, cam) == 0, "zero intensity scores zero")
}

@(test)
test_shadow_selection_caps_ranked :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]Caster
	casters := make_casters(20)
	count := select_shadow_casters(casters[:20], &maps, 100)
	testing.expect_value(t, count, SHADOW_RANKED_CASTERS)
	for i in 0 ..< 20 {
		testing.expect_value(t, holds_map(&maps, u32(i) + 1), i < SHADOW_RANKED_CASTERS)
	}
}

@(test)
test_shadow_selection_grace :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]Caster
	casters := make_casters(20)
	serial: u64 = 100
	select_shadow_casters(casters[:20], &maps, serial)
	// owner 12 drops to rank 13
	casters[11], casters[12] = casters[12], casters[11]
	last := casters[12].owner
	for frame in 1 ..= SHADOW_GRACE_FRAMES {
		select_shadow_casters(casters[:20], &maps, serial + u64(frame))
		testing.expect(t, holds_map(&maps, last), "keeps its map within grace")
	}
	select_shadow_casters(casters[:20], &maps, serial + SHADOW_GRACE_FRAMES + 1)
	testing.expect(t, !holds_map(&maps, last), "loses its map after grace")
}

@(test)
test_shadow_selection_unseen_evicted :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]Caster
	casters := make_casters(12)
	select_shadow_casters(casters[:12], &maps, 100)
	testing.expect(t, holds_map(&maps, 12), "visible caster holds a map")
	// owner 12 left every frustum: collect_lights drops it from the casters
	select_shadow_casters(casters[:11], &maps, 101)
	testing.expect(t, !holds_map(&maps, 12), "unseen caster loses its map at once")
}

@(test)
test_shadow_selection_grace_limited :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]Caster
	casters := make_casters(12)
	select_shadow_casters(casters[:12], &maps, 100)
	// 12 brighter lights (owners 21..32) push owners 1..12 to ranks 13..24
	next: [24]Caster
	for i in 0 ..< 12 do next[i] = {light = i, owner = u32(i + 21), score = 100}
	for i in 0 ..< 12 do next[12 + i] = {light = 12 + i, owner = u32(i) + 1, score = f32(12 - i)}
	count := select_shadow_casters(next[:], &maps, 101)
	testing.expect_value(t, count, MAX_SHADOW_MAPS)
	grace := 0
	for i in 0 ..< 12 do if holds_map(&maps, u32(i) + 1) do grace += 1
	testing.expect_value(t, grace, MAX_SHADOW_MAPS - SHADOW_RANKED_CASTERS)
}

@(test)
test_shadow_views_in_placement_order :: proc(t: ^testing.T) {
	// light handle i is row i; row 0 is none
	lights := [?]Light{{}, {type = .SPOT}, {type = .POINT}, {type = .DIRECTIONAL}}
	placements := [?]LightPlacement {
		{light = 1, shadow_map = 9}, // a stale view from the previous frame is cleared
		{light = 2},
		{light = 3},
		{light = 2},
	}
	picked := [?]bool{true, false, true, true}
	layers := assign_shadow_views(placements[:], lights[:], picked[:])
	// one shadow view per face, in table order: the spot light's one, the directional
	// light's cascades, then the point light's six
	testing.expect_value(t, placements[0].shadow_map, SHADOW_VIEW_BASE + 0)
	testing.expect_value(t, placements[1].shadow_map, 0)
	testing.expect_value(t, placements[2].shadow_map, SHADOW_VIEW_BASE + 1)
	testing.expect_value(t, placements[3].shadow_map, SHADOW_VIEW_BASE + 1 + SHADOW_CASCADES)
	testing.expect_value(t, layers, 1 + SHADOW_CASCADES + 6)
}
