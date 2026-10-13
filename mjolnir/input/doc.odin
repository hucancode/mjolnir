// Frame-coherent input. A window writes device events into an Accumulator;
// once per tick new_frame drains it into a State snapshot that the key_*,
// mouse_*, cursor, scroll, text and axis queries read. Key and button codes
// are in keys.odin.
package input
