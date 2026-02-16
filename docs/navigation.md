# Navigation Module (`mjolnir/navigation`, `recast`, `detour`)

```odin
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/recast"

cfg := recast.config_create()
geom := nav.NavigationGeometry{vertices = nav_vertices[:], indices = nav_indices[:], area_types = nav_area_types[:]}
if nav.build_navmesh(&engine.nav.nav_mesh, geom, cfg) && nav.init(&engine.nav) {
  path := nav.find_path(&engine.nav, start_pos, end_pos, 256)
}
```

Examples: `examples/navmesh/main.odin`
