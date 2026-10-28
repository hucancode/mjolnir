#+build !js
#+private file
package input

import "core:testing"

@(test)
test_key_edge_order :: proc(t: ^testing.T) {
	s, acc: State
	key_event(&acc, .A, .PRESS)
	key_event(&acc, .A, .RELEASE)
	key_event(&acc, .B, .PRESS)
	drain(&acc, &s)
	key_event(&acc, .B, .RELEASE)
	key_event(&acc, .B, .PRESS)
	drain(&acc, &s)
	it := 0
	k, p, ok := next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && !p, "re-pressed key: release first")
	k, p, ok = next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && p, "then press")
	_, _, ok = next_key_edge(&s, &it)
	testing.expect(t, !ok, "no more edges")
	testing.expect(t, key_down(&s, .B) && !key_pressed(&s, .A), "state")
}
