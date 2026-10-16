// Scene graph: nodes with parent/child links, local transforms and visibility. spawn nodes,
// move them with translate / rotate / scale, call update once per tick, then hand changes to
// consumers such as the renderer (render.stage_transforms). init/shutdown own its memory
// (application lifetime); teardown empties it between maps.
package world
