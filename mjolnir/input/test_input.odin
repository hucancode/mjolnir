#+build !js
#+private file
package input

import "core:testing"

@(test)
test_key_edge_order :: proc(t: ^testing.T) {
	s: State
	acc: Accumulator
	on_key(&acc, .A, .PRESS)
	on_key(&acc, .A, .RELEASE)
	on_key(&acc, .B, .PRESS)
	new_frame(&s, &acc)
	on_key(&acc, .B, .RELEASE)
	on_key(&acc, .B, .PRESS)
	new_frame(&s, &acc)
	it := 0
	k, p, ok := next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && !p, "re-pressed key: release first")
	k, p, ok = next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && p, "then press")
	_, _, ok = next_key_edge(&s, &it)
	testing.expect(t, !ok, "no more edges")
	testing.expect(t, key_down(&s, .B) && !key_pressed(&s, .A), "state")
}
