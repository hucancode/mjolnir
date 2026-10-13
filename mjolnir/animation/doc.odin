// Skeletal animation: a Rig (Skeleton + Clips) is played by an Animator made of
// blended Layers. Entry points: animator_init, animator_update, play and the
// add_*_layer procs (animator.odin); read results from Animator.palette / bone_matrix.
// Internals: clip/track sampling (clip.odin, track.odin), layer blending (layer.odin),
// FABRIK IK (ik.odin), tail/path/spider-leg modifiers (modifiers.odin), splines (spline.odin).
// glTF import lives in the animation/gltf subpackage.
package animation
