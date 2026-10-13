// Rigid-body physics: a World owns bodies, broad-phase BVHs and per-step contacts.
// Entry points: init, create_body, step, shutdown (physics.odin); queries in
// spatial_query.odin (raycast, overlaps); shapes in collider.odin, body state in rigid_body.odin.
// Internals (narrowphase, CCD, TGS-soft solver, integration, threading) are package-private.
package physics
