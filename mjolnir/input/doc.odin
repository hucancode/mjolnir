// Frame-coherent input. A window writes device events into an Accumulator; once per tick
// new_frame drains it into a State snapshot, read through its fields and the key_*, mouse_*,
// text and axis queries.
package input
