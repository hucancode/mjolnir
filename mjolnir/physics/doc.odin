// Rigid-body simulation and queries. Create bodies with colliders, step each tick and copy
// body_poses back into your scene; raycast and overlap to ask what is where.
package physics

// Internals: narrowphase, CCD, the TGS-soft solver, integration and threading are
// package-private (narrowphase.odin, ccd.odin, solver.odin, integration.odin, parallel.odin).
