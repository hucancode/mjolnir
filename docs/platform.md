---
title: Platform
---

Layer 2. Window and input over GLFW — the only module that imports
GLFW. Swap it out to run on another windowing library.

## Window

`platform.init` opens the window. `should_close` and
`poll_events(&p)` drive the loop. For Vulkan it exposes
`vulkan_instance_extensions`, `vulkan_get_instance_proc_addr` and
`create_surface`, plus `framebuffer_size` and `dpi_scale` for the
swapchain and UI.

`EventHooks` forward key, mouse button, cursor, scroll and character
events to a caller as they arrive (the engine routes them to the
debug UI).

## Input

Input is typed: `Key` (values match GLFW key codes; digits are
`NUM_0` … `NUM_9`), `MouseButton` (`LEFT`, `RIGHT`, `MIDDLE`,
`BUTTON_4` … `BUTTON_8`) and `Action` (`RELEASE`, `PRESS`, `REPEAT`).

`Input` accumulates raw events between polls. `input_new_frame`
snapshots them once per update tick, so the queries are stable for
the whole tick:

- `input_key_down` / `input_key_pressed` / `input_key_released`
- `input_mouse_down` / `input_mouse_pressed` / `input_mouse_released`
- `input_mouse_position`, `input_mouse_delta`, `input_scroll_delta`

Platform does not know about UI. Deciding which input a UI consumed
is the caller's job (the engine does it in `mjolnir/input.odin`).
