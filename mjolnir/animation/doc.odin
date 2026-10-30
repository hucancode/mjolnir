// Skeletal animation: stack layers on a rig (clips, IK, tails, paths, stepping legs or your own
// procedural code) and get the skinning palette to draw it with.
package animation

// Layer 2: systems

// Internals: clip/track sampling (clip.odin, track.odin); the layer stack and its update
// (animator.odin, layer.odin); the pose and its building blocks (pose.odin); one file per
// procedural kind (layer_tail.odin, layer_path.odin, layer_leg.odin; IK in ik.odin). A new
// kind is its params struct, an apply proc, a LayerParams member and a case in layer_apply's
// and layer_create's switches.
