// Package recast is a port of Recast: it turns triangle soup into a polygon
// mesh and detail mesh for detour. Entry point: build_navmesh with a Config;
// the individual pipeline stages (rasterize, filter, regions, contours, mesh,
// detail mesh) are exposed for custom builds. Most users go through
// navigation/bake instead.
package recast
