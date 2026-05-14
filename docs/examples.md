---
title: Examples
---

<style>
.example-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 1rem;
  margin: 1.5rem 0;
}
.example-grid figure {
  margin: 0;
  border: 1px solid var(--border);
  border-radius: 6px;
  overflow: hidden;
  background: var(--code-bg);
}
.example-grid video,
.example-grid .missing {
  display: block;
  width: 100%;
  aspect-ratio: 16 / 9;
  background: #000;
  object-fit: cover;
}
.example-grid .missing {
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--muted);
  font-family: monospace;
  font-size: 0.85rem;
}
.example-grid figcaption {
  padding: 0.5rem 0.75rem;
  font-family: monospace;
  font-size: 0.9rem;
  border-top: 1px solid var(--border);
}
.example-grid figcaption .desc {
  display: block;
  margin-top: 0.25rem;
  font-family: sans-serif;
  font-size: 0.85rem;
  color: var(--muted);
  line-height: 1.3;
}
</style>

<div class="example-grid">

<figure><video src="videos/animation_layering.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>animation_layering<span class="desc">Bone-mask layer blending across multiple clips.</span></figcaption></figure>

<figure><video src="videos/aoe.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>aoe<span class="desc">Area-of-effect indicators and particle bursts.</span></figcaption></figure>

<figure><video src="videos/blend_ik_fox.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>blend_ik_fox<span class="desc">FABRIK IK blended on top of skeletal animation.</span></figcaption></figure>

<figure><video src="videos/bullet_wall_ccd.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>bullet_wall_ccd<span class="desc">Continuous collision detection for fast projectiles.</span></figcaption></figure>

<figure><video src="videos/cameras.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>cameras<span class="desc">Multiple cameras rendered as bindless textures.</span></figcaption></figure>

<figure><video src="videos/crowd_nav.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>crowd_nav<span class="desc">Detour crowd agents navigating a navmesh.</span></figcaption></figure>

<figure><video src="videos/cube.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>cube<span class="desc">Minimal hello-world: textured spinning cube.</span></figcaption></figure>

<figure><video src="videos/debug_draw.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>debug_draw<span class="desc">Immediate-mode lines, boxes, spheres, text.</span></figcaption></figure>

<figure><video src="videos/forcefield.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>forcefield<span class="desc">GPU particle compute with force-field volumes.</span></figcaption></figure>

<figure><video src="videos/gltf_animation.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>gltf_animation<span class="desc">Skinned glTF playback with sampler controls.</span></figcaption></figure>

<figure><video src="videos/gltf_static.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>gltf_static<span class="desc">Static glTF asset loading and PBR rendering.</span></figcaption></figure>

<figure><video src="videos/grid.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>grid<span class="desc">Infinite reference grid shader.</span></figcaption></figure>

<figure><video src="videos/ik.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>ik<span class="desc">Standalone FABRIK chain reaching a target.</span></figcaption></figure>

<figure><video src="videos/input_demo.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>input_demo<span class="desc">Keyboard, mouse, and gamepad event plumbing.</span></figcaption></figure>

<figure><video src="videos/jump.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>jump<span class="desc">Character controller and jump arc.</span></figcaption></figure>

<figure><video src="videos/lights.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>lights<span class="desc">Point, spot, directional lights + shadows.</span></figcaption></figure>

<figure><video src="videos/material.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>material<span class="desc">PBR material parameter sweep.</span></figcaption></figure>

<figure><video src="videos/navmesh.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>navmesh<span class="desc">Recast build + Detour pathfinding overlay.</span></figcaption></figure>

<figure><video src="videos/obj_loader.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>obj_loader<span class="desc">Wavefront OBJ import.</span></figcaption></figure>

<figure><video src="videos/orthographic_camera.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>orthographic_camera<span class="desc">Orthographic projection setup.</span></figcaption></figure>

<figure><video src="videos/particles.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>particles<span class="desc">Compute-driven particle system.</span></figcaption></figure>

<figure><video src="videos/path_modifier.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>path_modifier<span class="desc">Procedural bone modifier following a spline.</span></figcaption></figure>

<figure><video src="videos/pbr.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>pbr<span class="desc">IBL + deferred PBR showcase.</span></figcaption></figure>

<figure><video src="videos/physics.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>physics<span class="desc">Rigid-body stack with BVH broadphase.</span></figcaption></figure>

<figure><video src="videos/post_process.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>post_process<span class="desc">Bloom, DoF, fog, tonemap, outline, crosshatch.</span></figcaption></figure>

<figure><video src="videos/procedural_mesh.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>procedural_mesh<span class="desc">Mesh generated at runtime.</span></figcaption></figure>

<figure><video src="videos/render_to_texture.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>render_to_texture<span class="desc">Render-target → bindless texture pipeline.</span></figcaption></figure>

<figure><video src="videos/scene_graph.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>scene_graph<span class="desc">Hierarchical transforms and traversal.</span></figcaption></figure>

<figure><video src="videos/snake.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>snake<span class="desc">Snake game built on the engine.</span></figcaption></figure>

<figure><video src="videos/spider_leg.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>spider_leg<span class="desc">Procedural IK leg planting.</span></figcaption></figure>

<figure><video src="videos/spider_leg_modifier.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>spider_leg_modifier<span class="desc">Leg modifier integrated into the rig.</span></figcaption></figure>

<figure><video src="videos/spline.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>spline<span class="desc">Spline evaluation and visualization.</span></figcaption></figure>

<figure><video src="videos/split_screen.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>split_screen<span class="desc">Multiple viewports sharing one scene.</span></figcaption></figure>

<figure><video src="videos/sprite.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>sprite<span class="desc">2D sprite batching.</span></figcaption></figure>

<figure><video src="videos/tail_modifier.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>tail_modifier<span class="desc">Procedural tail follow-through modifier.</span></figcaption></figure>

<figure><video src="videos/torus_tetris.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>torus_tetris<span class="desc">Tetris on a torus topology.</span></figcaption></figure>

<figure><video src="videos/transparent.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>transparent<span class="desc">Order-dependent transparency pass.</span></figcaption></figure>

<figure><video src="videos/ui.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>ui<span class="desc">2D UI widgets, layout, events, fontstash text.</span></figcaption></figure>

<figure><video src="videos/wireframe.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>wireframe<span class="desc">Wireframe rendering pipeline.</span></figcaption></figure>

</div>

<script>
// hide videos that 404 so the page degrades cleanly before record.sh has run
document.querySelectorAll('.example-grid video').forEach(v => {
  v.addEventListener('error', () => {
    const fig = v.closest('figure');
    if (!fig) return;
    const ph = document.createElement('div');
    ph.className = 'missing';
    ph.textContent = 'video not yet recorded';
    fig.replaceChild(ph, v);
  });
});
</script>
