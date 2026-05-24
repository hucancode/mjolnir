---
title: World
---

Layer 2. CPU-side authoritative state for the scene graph: nodes,
meshes, materials, cameras, lights, animations, sprites, emitters,
force fields, rigid-body attachments. `render` only reads from here —
never the reverse.

## Scene graph

`Node` carries a `Transform`, a parent + children, a `NodeTagSet`,
and a `NodeAttachment` union (mesh / light / emitter / forcefield /
sprite / rigid body). Hierarchical transforms cascade parent → child.
Lookups are via generational handles (`NodeHandle`, `MeshHandle`, …)
backed by `containers.Pool`.

`traverse` walks the dirty subtree and recomputes world matrices.
Nothing recomputes unless something upstream moved.

## Staging, not GPU writes

The world module **must not** touch GPU buffers directly. Every
mutator (`spawn`, `translate`, `set_material_handle`, …) appends to a
private staging queue. The engine drains the queue once per frame on
the render thread inside `sync_staging_to_gpu` and forwards the
entries to `render`.

This is the single-source-of-truth contract. CPU state in `world` is
authoritative; GPU state is a mirror. Drift is impossible because
drift would require two writers, and `render` only ever reads.

See [architecture](architecture.html) for the staging pipeline and
the `FRAMES_IN_FLIGHT` age rule that defers GPU releases.

## Cameras

Each `Camera` carries a `PassTypeSet` describing which passes run for
it. The same scene can host a main camera, shadow casters, minimap
cameras, and offscreen render targets — each with its own pass set
and attachments. The composition story (camera-B's output as a
texture in camera-A) is just "sample a bindless handle"; the engine
side does no special casing.

## Animation

`world` is the layer that *applies* the data structures from
`animation/`. Per skinned node it runs FK clip sampling, then any IK
or procedural modifier layers, blends them by weight + bone mask,
and writes the resulting bone matrices into the node's skinning
buffer.

Layer types: `FKLayer` (sampled clip), `IKLayer` (FABRIK target),
`ProceduralLayer` (tail / path / spider-leg / single-bone-rotation
modifiers). Layers blend in insertion order using the layer's
`BlendMode` (REPLACE / ADD / MULTIPLY / OVERRIDE).

## glTF / OBJ

`world.load_gltf` and `world.load_obj` populate nodes + meshes +
materials + skeletons + clips in one pass. The engine wrapper
`mjolnir.load_gltf` injects the texture allocator so glTF textures
land in the bindless arena automatically.
