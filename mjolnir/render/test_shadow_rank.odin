#+private file
package render

import "core:testing"
import "gpu"
import vk "vendor:vulkan"

// Casters with descending scores, owners 1..n.
make_casters :: proc(n: int) -> (casters: [MAX_LIGHTS]Caster) {
	for i in 0 ..< n do casters[i] = {light = i, owner = u32(i) + 1, score = f32(n - i)}
	return
}

// Run selection for one frame and hand out maps the way collect_lights does.
select_frame :: proc(casters: []Caster, maps: ^[MAX_SHADOW_MAPS]ShadowMap, serial: u64) -> int {
	selected, count := select_shadow_casters(casters, maps, serial)
	claimed: [MAX_SHADOW_MAPS]bool
	for c in selected[:count] do if c.shadow_map >= 0 do claimed[c.shadow_map] = true
	for &sm, m in maps do if !claimed[m] do sm.owner = 0
	for c in selected[:count] {
		m := c.shadow_map
		if m < 0 do for _, free in maps do if !claimed[free] {m = free; break}
		claimed[m] = true
		maps[m].owner = c.owner
		maps[m].last_ranked = c.last_ranked
	}
	return count
}

holds_map :: proc(maps: ^[MAX_SHADOW_MAPS]ShadowMap, owner: u32) -> bool {
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
	unbounded := shadow_score({0, 0, 100, UNBOUNDED_LIGHT_RADIUS}, 1, cam)
	testing.expect(t, near > far, "closer light scores higher")
	testing.expect(t, large > near, "larger light scores higher")
	testing.expect(t, bright > near, "brighter light scores higher")
	testing.expect(t, inside > large, "camera inside the sphere scores highest")
	testing.expect(t, unbounded >= inside, "an unbounded light scores highest")
	testing.expect(t, shadow_score({0, 0, 100, UNBOUNDED_LIGHT_RADIUS}, 0, cam) == 0, "zero intensity is finite")
}

@(test)
test_shadow_selection_caps_ranked :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]ShadowMap
	casters := make_casters(20)
	count := select_frame(casters[:20], &maps, 100)
	testing.expect_value(t, count, SHADOW_RANKED_CASTERS)
	for i in 0 ..< 20 {
		testing.expect_value(t, holds_map(&maps, u32(i) + 1), i < SHADOW_RANKED_CASTERS)
	}
}

@(test)
test_shadow_selection_grace :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]ShadowMap
	casters := make_casters(20)
	serial: u64 = 100
	select_frame(casters[:20], &maps, serial)
	// owner 12 drops to rank 13
	casters[11], casters[12] = casters[12], casters[11]
	last := casters[12].owner
	for frame in 1 ..= SHADOW_GRACE_FRAMES {
		select_frame(casters[:20], &maps, serial + u64(frame))
		testing.expect(t, holds_map(&maps, last), "keeps its map within grace")
	}
	select_frame(casters[:20], &maps, serial + SHADOW_GRACE_FRAMES + 1)
	testing.expect(t, !holds_map(&maps, last), "loses its map after grace")
}

@(test)
test_shadow_selection_unseen_evicted :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]ShadowMap
	casters := make_casters(12)
	select_frame(casters[:12], &maps, 100)
	testing.expect(t, holds_map(&maps, 12), "visible caster holds a map")
	// owner 12 left every frustum: collect_lights drops it from the casters
	select_frame(casters[:11], &maps, 101)
	testing.expect(t, !holds_map(&maps, 12), "unseen caster loses its map at once")
}

@(test)
test_shadow_selection_grace_limited :: proc(t: ^testing.T) {
	maps: [MAX_SHADOW_MAPS]ShadowMap
	casters := make_casters(12)
	select_frame(casters[:12], &maps, 100)
	// 12 brighter lights (owners 21..32) push owners 1..12 to ranks 13..24
	next: [24]Caster
	for i in 0 ..< 12 do next[i] = {light = i, owner = u32(i + 21), score = 100}
	for i in 0 ..< 12 do next[12 + i] = {light = 12 + i, owner = u32(i) + 1, score = f32(12 - i)}
	count := select_frame(next[:], &maps, 101)
	testing.expect_value(t, count, MAX_SHADOW_MAPS)
	grace := 0
	for i in 0 ..< 12 do if holds_map(&maps, u32(i) + 1) do grace += 1
	testing.expect_value(t, grace, MAX_SHADOW_MAPS - SHADOW_RANKED_CASTERS)
}

@(test)
test_shadow_views_per_light :: proc(t: ^testing.T) {
	depth := gpu.Image {
		view       = vk.ImageView(1),
		face_views = {vk.ImageView(10), vk.ImageView(11), vk.ImageView(12), vk.ImageView(13), vk.ImageView(14), vk.ImageView(15)},
	}
	cube := ShadowMap{cube = true}
	flat := ShadowMap{}
	point := FrameLight{shadow_map = &cube}
	spot := FrameLight{shadow_map = &flat}
	testing.expect_value(t, shadow_view_count(&cube), 6)
	testing.expect_value(t, shadow_view_count(&flat), 1)
	for face in 0 ..< 6 {
		v := shadow_view(&point, &depth, face)
		testing.expect_value(t, v.target, depth.face_views[face])
		testing.expect_value(t, v.flip_y, false)
		testing.expect_value(t, v.front_face, vk.FrontFace.CLOCKWISE)
	}
	v := shadow_view(&spot, &depth, 0)
	testing.expect_value(t, v.target, depth.view)
	testing.expect_value(t, v.flip_y, true)
	testing.expect_value(t, v.front_face, vk.FrontFace.COUNTER_CLOCKWISE)
}
