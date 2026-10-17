#+build !js
#+private file
package platform

import "core:testing"
import "../input"

@(test)
test_key_edge_order :: proc(t: ^testing.T) {
	s: input.State
	acc: Accumulator
	acc_key(&acc, .A, .PRESS)
	acc_key(&acc, .A, .RELEASE)
	acc_key(&acc, .B, .PRESS)
	acc_drain(&acc, &s)
	acc_key(&acc, .B, .RELEASE)
	acc_key(&acc, .B, .PRESS)
	acc_drain(&acc, &s)
	it := 0
	k, p, ok := input.next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && !p, "re-pressed key: release first")
	k, p, ok = input.next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && p, "then press")
	_, _, ok = input.next_key_edge(&s, &it)
	testing.expect(t, !ok, "no more edges")
	testing.expect(t, input.key_down(&s, .B) && !input.key_pressed(&s, .A), "state")
}
