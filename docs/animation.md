---
title: Animation
---

Layer 2. Headless animation: it animates values, vectors and bone
hierarchies, and knows nothing about scene nodes or GPU buffers. It
imports only `geometry` and `core`. The caller decides where results
go: a node transform, a light intensity, a skin palette upload. See
[engine](engine.html#wiring-modules) for the standard wiring.

The package has three tiers. Each tier builds on the one below, and
each is usable on its own.

## Tier 1: values

**Tracks.** `Track(T)` is a keyframed curve over flat arrays:
`times []f32`, `values []T` and one `Interpolation` (`LINEAR`, `STEP`
or `CUBIC`). A track is a view and does not own memory. `CUBIC`
stores three values per key (in-tangent, value, out-tangent), the
glTF layout. `track_sample(track, t, fallback)` clamps to the first
and last key; rotations slerp.

**Playback.** `playback_advance(&time, &speed, &status, mode,
duration, dt)` advances a play head. `LOOP` wraps, `ONCE` clamps and
stops, `PING_PONG` flips the speed at either end.

**Splines.** `Spline(T)` is Catmull-Rom over any vector type.
`spline_build_arc_table` + `spline_sample_uniform` resample it at
uniform arc length. Used for camera moves, paths and the path
modifier.

## Clips

A `Clip` is a set of channels sharing one timeline. A `Channel` has
three `TrackRange`s (position, rotation, scale), each pointing into
the clip's flat key arrays: one `times`, one `positions`, one
`rotations`, one `scales`. A clip with any number of channels is a
handful of allocations, never one per bone.

```odin
clip: anim.Clip
anim.clip_init(&clip, channel_count = 1, name = "spin", duration = 2)
anim.clip_set_rotations(&clip, 0, times, rotations, .LINEAR)
trs := anim.TRS_IDENTITY
anim.clip_sample_trs(&clip, 0, t, &trs) // unanimated components keep their input value
```

`clip_position_track` / `clip_rotation_track` / `clip_scale_track`
return a channel component as a `Track` view.

## Tier 2: skeletons

`Skeleton` is the shared, immutable **definition** of a bone
hierarchy. It is SoA, one flat array per attribute indexed by bone:

| Field | Meaning |
|---|---|
| `names`, `parents` | bone name, parent index (-1 = root) |
| `order` | bone indices with every parent before its children |
| `rest` | local rest pose (`TRS`) |
| `bind`, `inverse_bind` | skeleton-space rest pose and its inverse |
| `lengths`, `depths` | rest distance to parent, depth from root |

`skeleton_init(&s, parents, inverse_bind, names)` copies its inputs,
derives the rest pose from the inverse binds, and fails on cycles or
out-of-range parents. Bone queries: `find_bone`, `find_bones`,
`bone_chain` (root → tip), `bone_chain_down`, `bone_mask`,
`bone_subtree_mask`, `rest_position`, `rest_offset`.

A `Rig` is the asset type: one skeleton plus the clips authored for
it. `find_clip(rig, name)` looks a clip up within that rig.

## Tier 3: animators

An `Animator` is the **per-instance** state of one skeleton. It owns
a layer stack, an optional transition, and flat per-bone pose arrays
carved out of one allocation:

- `local` — per-bone local transform (`TRS`).
- `positions`, `rotations`, `scales` — per-bone skeleton-space
  transform, the parent chain applied in one linear pass over `order`
  (scale composes per axis, without shear).
- `palette` — skeleton-space matrix `* inverse_bind`, what a renderer
  uploads.

Many animators can share one rig; none of them writes to it.

```odin
a: anim.Animator
anim.animator_init(&a, rig)
defer anim.animator_destroy(&a)
anim.play(&a, rig, "walk")
// every tick
palette := anim.animator_update(&a, rig, dt, root_world)
```

`animator_update` runs this pipeline:

1. Advance every clip layer's play head and the transition.
2. Blend the clip layers into `local`, honouring weight, blend mode
   and bone mask. Bones no layer touches stay at rest.
3. Pose the skeleton-space arrays from `local`.
4. Run procedural layers on the skeleton-space pose, then re-pose the
   descendants of the bones they moved.
5. Run IK layers the same way.
6. Write `palette`.

`root_world` is the skinned object's world matrix. World-space IK
targets and the procedural modifiers read it; nothing else does.

### Layers

Each `Layer` has a `weight`, a `BlendMode` (`REPLACE`, `ADD`,
`MULTIPLY`, `OVERRIDE`) and an optional bone mask. Layers apply in
stack order. Positions blend by weighted sum, rotations by weighted
slerp, scales by weighted product.

| Layer | Added with | Does |
|---|---|---|
| clip | `play`, `add_clip_layer`, `add_clip_layer_index` | samples one rig clip |
| IK | `add_ik_layer`, `add_ik_chain_layer` | FABRIK on a bone chain toward a target, `LOCAL` or `WORLD` space |
| tail | `add_tail_layer` | bones lag behind parent motion with damping |
| path | `add_path_layer` | bones ride a spline |
| spider leg | `add_spider_leg_layer` | feet step toward targets with a parabolic lift |

Layer constructors take the `^Rig` the animator plays. A spider-leg
layer takes one `SpiderLegConfig` per leg: chain root and length,
optional constraints, rest foot offset and step timing.

`set_layer_weight`, `set_layer_mask`, `set_ik_target`,
`set_ik_enabled`, `set_tail_params`, `set_path_params`,
`set_spider_leg_params` and `spider_leg_target` adjust a
layer after it is added. `remove_layer` and `clear_layers` drop them.

`transition_to(&a, rig, name, duration, from, to, curve)` cross-fades
from one layer to another along an easing curve; the transition's
state reads `COMPLETE` on the tick it finishes.

### Reading the pose

- `bone_matrix(&a, bone)` — skeleton-space matrix of a bone, for
  sockets.
- `bone_segments(&a, skel, root_world)` — world-space parent → child
  segments, for debug drawing; feed each to `render.debug_segment`.

## FABRIK

Two-sweep iterative IK: the forward pass pins the tip to the target,
the backward pass pins the root, repeat until within tolerance. No
matrix inversion, no Jacobian, quick to converge on typical chains.
Per-bone swing and twist constraints (`IKBoneConstraint`) limit each
joint.
