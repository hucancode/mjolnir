---
title: Render
---

Layer 2. GPU-driven, bindless, deferred-shading renderer. The engine
records the entire pipeline each frame; user code mostly chooses
material types, light kinds, and a post-process effect stack — the
pipeline itself is fixed.

## Why deferred + light volumes

Forward shading scales as `pixels × lights`. The deferred pass writes
a G-buffer (position, normal, albedo, metallic-roughness, emissive,
depth) once per visible fragment, then runs one fullscreen ambient
pass (IBL + BRDF LUT) plus a per-light volume pass for each direct
light. A light's volume (sphere for point, cone for spot, fullscreen
triangle for directional) is rasterized with reversed depth test so
only fragments actually reached by that light get shaded. Avoids the
"shade every pixel against every light" loop without needing a tile
or cluster pass.

## Bindless + GPU-driven culling

All textures live in one descriptor array; all geometry lives in a
handful of giant vertex / index / skinning buffers. A draw is just
"indirect dispatch + bindless indices" — there is no per-mesh
descriptor binding. Visibility culling runs as a compute pass per
camera (frustum + depth-pyramid occlusion) and writes the indirect
draw commands the next graphics pass will consume.

## Shadows

Two strategies, picked per light type:

- **2D shadow maps** for directional + spot lights. One compute pass
  per light clips draws against the light frustum; one depth-only
  graphics pass writes a 512² R32_SFLOAT slice.
- **Cubemap shadow maps** for point lights. One compute pass clips
  against the light's sphere; one geometry-shader-amplified draw
  writes all six faces. Requires
  `-define:REQUIRE_GEOMETRY_SHADER=true` at build time.

Shadow buffers are allocated lazily on the first cast and released
when the light despawns.

## Post-process

Each camera has an effect stack pushed via
`render.post_process.add_*`. Effects run in insertion order inside
the `POST_PROCESS` pass: tonemap, bloom, blur, fog, outline, DoF,
crosshatch, grayscale. Built as small fullscreen passes against the
camera's FINAL_IMAGE attachment.

## Camera attachments

Each camera owns per-frame `Texture2DHandle`s for every G-buffer
slot. `mjolnir.get_camera_attachment(engine, cam, .FINAL_IMAGE)`
returns a bindless handle — feed it to a UI quad or a material to
composite that camera's output anywhere (minimaps, mirrors,
render-to-texture surfaces).
