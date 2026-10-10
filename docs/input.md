---
title: Input
---

Layer 1. Frame-coherent keyboard and mouse input, independent of any
windowing library. A window writes device events into an
`Accumulator` as they arrive; once per tick `new_frame` drains it into
a `State` snapshot, so every query is stable for the whole tick no
matter how often events are polled. Presses and releases are recorded
per event: a tap that starts and ends between two ticks still reports
both edges.

## Types

`Key` (values match GLFW key codes; digits are `NUM_0` … `NUM_9`),
`MouseButton` (`LEFT`, `RIGHT`, `MIDDLE`, `BUTTON_4` … `BUTTON_8`)
and `Action` (`RELEASE`, `PRESS`, `REPEAT`).

## Writing

The window calls `on_key`, `on_button`, `on_cursor`, `on_scroll` and
`on_char` on its `Accumulator`. Scroll is summed between ticks; typed
text is buffered as UTF-8 up to `TEXT_CAPACITY` bytes per tick.

## Reading

```odin
input.new_frame(&state, &acc) // once per tick, before any query
if input.key_pressed(&state, .SPACE) do jump()
move := input.axis(&state, .A, .D)
```

- `key_down` / `key_pressed` / `key_released` / `key_repeated`
- `mouse_down` / `mouse_pressed` / `mouse_released`
- `cursor` (window pixels, origin top-left), `mouse_delta`, `scroll`
- `text` — UTF-8 typed this tick
- `axis(neg, pos)` — -1, 0 or +1 from two keys
- `next_key_edge` — iterate this tick's key edges in the order that
  leaves each key in its current state:

```odin
it := 0
for key, pressed in input.next_key_edge(&state, &it) { ... }
```

The engine snapshots `engine.platform.input` into `engine.input` at
the start of every update tick; read it in the `update` callback.
Input does not know about UI. Deciding which input a UI consumed is
the caller's job (the engine sets `engine.mouse_captured` /
`engine.keyboard_captured`).
