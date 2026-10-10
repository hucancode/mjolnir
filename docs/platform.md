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
events into `p.input`, an [`input`](input.html) `Accumulator`, as
`poll_events` delivers them. Turning that into a per-tick snapshot is
the caller's job (`input.new_frame`). A `Platform` must not move
after `init`; the GLFW callbacks keep a pointer to it.
