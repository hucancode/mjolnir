// Skeletal animation. A Rig (a Skeleton plus its Clips) is shared asset data; an Animator is
// one instance playing it as a stack of blended Layers: clips, IK chains and procedural
// modifiers (tail, path, spider legs). Set up with animator_init, add layers with play or the
// add_*_layer procs, then call animator_update each tick and upload the skinning palette it
// returns. Free with animator_destroy and rig_destroy.
package animation

// Internals: clip/track sampling (clip.odin, track.odin), layer blending (layer.odin),
// FABRIK IK (ik.odin), tail/path/spider-leg modifiers (modifiers.odin), splines (spline.odin).
