---
title: Navigation
---

Layer 2. Recast builds navmeshes, Detour queries them, and Crowd
steers many agents across them. Navigation takes plain triangles and
knows nothing about meshes or nodes; the application owns its
`NavMesh` and crowds.

The module splits into a runtime and a baker. `navigation` (the
`NavMesh` and its queries), `navigation/detour` and
`navigation/crowd` never import Recast, so a game that loads
pre-baked data ships without the baker. `navigation/bake` turns
triangles into a `NavMesh`.

## Building

All building procs live in `navigation/bake`.

1. **Gather triangles.** `bake.append_triangles(&builder, positions,
   indices, offset, is_obstacle)` adds a triangle mesh to a
   `NavGeometryBuilder`; obstacle triangles are carved out. Or fill a
   `NavigationGeometry{vertices, indices, area_types}` directly.
2. **Build.** `bake.build(&nav, geometry_view(&builder), config)` runs
   Recast (voxelize, erode by agent radius, trace contours,
   triangulate into polygons), then creates the Detour mesh and its
   query. It replaces any previous build and returns `false` on
   failure.
3. **Clean up.** `bake.builder_destroy` frees the builder once the
   mesh is built; `navigation.destroy` frees the mesh.

`navigation.init(&nav, data, params)` loads single-tile Detour data
baked earlier, with no Recast involved.

`debug_triangles(&nav)` returns the built polygons as positions +
indices for drawing.

## Quality knobs

`bake.NavMeshConfig` is agent-centric: height, radius, max climb, max
slope and a `quality ∈ {LOW, MEDIUM, HIGH, ULTRA}` that selects the
voxel cell size and contour simplification thresholds. Lower quality
means a faster bake and a coarser mesh, fine for big open areas;
higher quality suits small intricate spaces. `DEFAULT_NAVMESH_CONFIG`
uses `MEDIUM`.

## Queries

- `find_path(&nav, start, end)` returns straight-line waypoints, with
  both ends snapped to the mesh within `extents`. The caller deletes
  the path.
- `nearest_point(&nav, pos, extents)` projects an off-mesh position
  onto the navmesh.
- `raycast(&nav, origin, dir, max_t)` returns the nearest point where
  a ray hits the navmesh surface; feed it the cursor ray to turn a
  click into a goal.

## Crowd

`navigation/crowd` moves agents along the navmesh with path
corridors, obstacle avoidance and separation:

```odin
c, _ := crowd.create(max_agents, max_agent_radius, &nav)
defer crowd.destroy(c)
params := crowd.DEFAULT_AGENT_PARAMS
params.max_speed = 5
id := crowd.add_agent(c, spawn_pos, params)
crowd.move_to(c, id, goal)
// every tick
crowd.update(c, dt)
pos := crowd.get_agent(c, id).npos
```

`Agent_Params` sets radius, height, speed, acceleration and which
behaviours run (`update_flags`, a bit_set such as
`{.Anticipate_Turns, .Separation}`); `DEFAULT_AGENT_PARAMS` is a
ready-made starting point. Copying agent positions onto
nodes is application glue. Walking a single `find_path` result
without a crowd is also the caller's job.

## Submodules

`navigation/recast`, `navigation/detour` and `navigation/crowd` are
usable directly for anything `bake.build` does not cover (tiled
meshes, custom filters, area costs). Recast is the offline baker;
Detour is the runtime and never imports Recast. Crowd runs on Detour
and takes the top-level `NavMesh`. `navigation/bake` bridges Recast
and Detour: `bake.create_nav_mesh_data` converts a Recast `Poly_Mesh`
into Detour tile data, and `bake.bake_and_save_navmesh` writes it to
a file that `detour.load_navmesh_for_runtime` loads.
