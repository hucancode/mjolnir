---
title: Animation
---

Layer 1. Pure animation data + procs: keyframes, clips, splines,
FABRIK IK, procedural modifiers. Knows nothing about scene nodes or
GPU buffers — `world` is the layer that applies these to skeletons.

## Keyframe sampling

`Keyframe(T)` is a union of `Linear`, `Step`, and `CubicSpline`
variants. `keyframe_sample` dispatches to the right interpolator pair
based on the two surrounding keyframes — so a single track can mix
interpolation modes per segment (matches glTF authoring conventions).

A `Clip` is `name + duration + []Channel`. A `Channel` is per-bone
position / rotation / scale tracks. `channel_sample_all` returns the
trio at time `t`.

## Layers + blending

Animation is layered. Each `Layer` carries a `weight`, a `BlendMode`
(REPLACE / ADD / MULTIPLY / OVERRIDE), and an optional `bone_mask`
to restrict its influence to a chain.

- **FKLayer** — sampled clip + play state (`LOOP` / `ONCE` /
  `PING_PONG`, speed).
- **IKLayer** — FABRIK target plus pole hint.
- **ProceduralLayer** — tail / path / spider-leg / single-bone
  rotation modifiers.

Layers blend in insertion order. Position uses weighted addition,
rotation uses SLERP, scale uses weighted multiplication — same shape
as Unity's animation layer stack.

## FABRIK

Two-sweep iterative IK: forward pass anchors the tip to the target,
backward pass anchors the root, repeat until tolerance. Cheap, no
matrix inversion, no Jacobian, converges quickly for typical bone
chains. The pole hint biases the bending plane so elbows and knees
don't flip.

## Procedural modifiers

- **Tail** — bones counter-rotate parent motion with damping. Gives
  hair, antennas, tails their follow-through.
- **Path** — bones distribute along a spline that follows a path,
  useful for tentacles / ribbons tracking a route.
- **Spider-leg** — per-leg parabolic foot-lift driven by root motion;
  each leg lifts when its target drifts too far from where the foot
  currently is.

## Spline

Catmull-Rom over any vector type with optional uniform arc-length
resampling — used by paths, camera moves, and the path modifier.
