---
title: GPU
---

Thin Vulkan 1.3 abstraction. **Does not** hide Vulkan — it codifies
the patterns mjolnir relies on (bindless texture array, slab-allocated
mesh buffers, dynamic rendering, frame-in-flight semaphores). Most
user code never touches this directly; it exists for `render` and as
an escape hatch.

## Design choices

- **No render-graph, no auto-barrier inference.** Passes record their
  own barriers. Easier to reason about, easier to debug in RenderDoc,
  no surprise hazards.
- **Dynamic rendering only.** No `VkRenderPass` / `VkFramebuffer`
  objects. Attachments come from `begin_rendering` per pass.
- **Bindless first.** Every sampled texture goes through one big
  descriptor array (`TextureManager`); every mesh goes through one
  vertex / index / skinning buffer (`MeshManager`). Draw calls pass
  indices, not descriptor sets.
- **Pre-baked pipeline state.** Common rasterizer / blend / depth
  states are exposed as `ALL_CAPS` constants so pipelines compose
  declaratively instead of repeating boilerplate.

## Key subsystems

- `GPUContext` — instance, device, queues, descriptor pool, command
  pools. One per engine.
- `Swapchain` — frames-in-flight fences and semaphores, presentation.
- `TextureManager` — bindless arena for 2D + cube textures. Allocations
  return a `Texture2DHandle` / `TextureCubeHandle` (a generational
  index into the descriptor array).
- `MeshManager` — three immutable GPU buffers (vertex / index /
  skinning) sub-allocated via slab allocators. Mesh allocation returns
  stable byte offsets that draw-indirect commands reference directly.
- `MutableBuffer(T)` / `ImmutableBuffer(T)` — typed wrappers around
  host-visible vs device-local memory. `MutableBuffer` is mapped for
  CPU writes; `ImmutableBuffer.write` uploads via a one-shot staging
  buffer.

## Frames in flight

`FRAMES_IN_FLIGHT = 2` by default. Per-frame resources (semaphores,
per-camera attachments, staging buffers) are indexed by
`frame_index % FRAMES_IN_FLIGHT`. Anything the GPU might still be
reading must outlive that window — see
[architecture](architecture.html) for the staging-age rule.
