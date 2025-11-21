package physics

import "../geometry"

raycast :: proc {
  geometry.bvh_raycast,
  geometry.octree_raycast,
}

raycast_single :: proc {
  geometry.bvh_raycast_single,
  geometry.octree_raycast_single,
}

raycast_multi :: proc {
  geometry.bvh_raycast_multi,
  geometry.octree_raycast_multi,
}

query_sphere :: proc {
  geometry.bvh_query_sphere,
  geometry.octree_query_sphere
}

query_box :: proc {
  geometry.bvh_query_aabb,
  geometry.octree_query_aabb,
}
