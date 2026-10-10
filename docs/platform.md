---
title: Platform
---

Layer 2. A window over GLFW — the only module that imports GLFW. Swap
it out to run on another windowing library.

`platform.init` opens the window. `should_close` and
`poll_events(&p)` drive the loop. For Vulkan it exposes
`vulkan_instance_extensions`, `vulkan_get_instance_proc_addr` and
`create_surface`, plus `framebuffer_size` and `dpi_scale` for the
swapchain and UI.

The window writes key, mouse button, cursor, scroll and character
events into an [`input`](input.html) `Accumulator` as `poll_events`
delivers them. `read_input(&p, &state)` drains it into the tick's
`input.State`. `create_surface` takes the `^Platform` as a `rawptr`, so
a renderer can take it as a callback without importing platform. A
`Platform` must not move after `init`; the GLFW callbacks keep a
pointer to it.
