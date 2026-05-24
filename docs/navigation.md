---
title: Navigation
---

Recast for navmesh generation, Detour for pathfinding. The engine
owns one `NavigationSystem` at `engine.nav`.

## Pipeline

1. **Gather geometry.** Either bake from the scene graph
   (`mjolnir.setup_navmesh` with tag filters) or feed an explicit
   `NavigationGeometry{vertices, indices, area_types}` via
   `NavGeometryBuilder`.
2. **Voxelize → contours → polygons.** Recast voxelizes the input
   into a heightfield, erodes by agent radius, traces contours,
   triangulates, and produces a polygon mesh.
3. **Bind query context.** A Detour query object is attached so
   `find_path` / `find_nearest_point` work against the engine.

## Quality knobs

`NavMeshConfig.quality ∈ {LOW, MEDIUM, HIGH, ULTRA}` selects the
voxel cell size and contour simplification thresholds. Lower quality
= faster bake + coarser mesh; useful for big open areas. Higher
quality = small intricate spaces. `MEDIUM` is the recommended
default. For full control, hand a `recast.Config` to `build_navmesh`
directly.

## Area costs

`area_types[i] = 0` is walkable; nonzero indexes
`NavMesh.area_costs[]` to weight terrain (sand slower than asphalt,
swamp slower than dirt) without making it impassable. Path search
follows the cost-weighted shortest path.

## Pathfinding

`find_path` returns `[][3]f32` (an empty slice if no path).
`find_nearest_point` projects an off-mesh position onto the navmesh —
the usual idiom is to combine it with a mouse-pick raycast to convert
a click into a valid goal before pathing.

Walking the path is the caller's job: the engine does not own agent
movement. See the navigation example for the canonical lerp-toward-
next-waypoint loop.
