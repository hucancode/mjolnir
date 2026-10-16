// Rigid-body physics. A World owns bodies with sphere, box or cylinder colliders: body_create,
// apply_force / set_velocity / set_pose, step once per tick, then body_poses to copy the moved
// bodies back into a scene graph. raycast and overlap query the world. init/shutdown own its
// memory (application lifetime); teardown empties it between maps.
package physics

// Internals: narrowphase, CCD, the TGS-soft solver, integration and threading are
// package-private (narrowphase.odin, ccd.odin, solver.odin, integration.odin, parallel.odin).
