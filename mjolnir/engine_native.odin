#+build !js
package mjolnir

@(private)
run_loop :: proc(loop: Loop(byte)) {
  r := Runner{loop = loop}
  for step(&r) {}
  stop(&r)
}
