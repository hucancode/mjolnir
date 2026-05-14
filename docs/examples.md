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
.example-grid details {
  border-top: 1px solid var(--border);
  font-family: sans-serif;
  font-size: 0.85rem;
}
.example-grid details > summary {
  padding: 0.4rem 0.75rem;
  cursor: pointer;
  user-select: none;
  color: var(--muted);
  list-style: none;
}
.example-grid details > summary::-webkit-details-marker { display: none; }
.example-grid details > summary::before {
  content: "▸ ";
  display: inline-block;
  width: 1em;
}
.example-grid details[open] > summary::before { content: "▾ "; }
.example-grid details > summary:hover { color: var(--fg, inherit); }
.example-grid details pre {
  margin: 0;
  max-height: 24rem;
  overflow: auto;
  border-top: 1px solid var(--border);
  border-radius: 0;
  font-size: 0.78rem;
  line-height: 1.4;
}
.example-grid details pre code {
  white-space: pre;
  background: transparent;
  padding: 0.5rem 0.75rem;
  display: block;
}
</style>

<div class="example-grid">

<figure data-example="cube"><video src="videos/cube.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>cube<span class="desc">Minimal hello-world cube.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/cube/main.odin">Loading…</code></pre></details></figure>

<figure data-example="animation_layering"><video src="videos/animation_layering.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>animation_layering<span class="desc">Bone-mask layer blending across multiple clips.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/animation_layering/main.odin">Loading…</code></pre></details></figure>

<figure data-example="aoe"><video src="videos/aoe.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>aoe<span class="desc">Area-of-effect query</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/aoe/main.odin">Loading…</code></pre></details></figure>

<figure data-example="bullet_wall_ccd"><video src="videos/bullet_wall_ccd.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>bullet_wall_ccd<span class="desc">Continuous collision detection for fast projectiles.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/bullet_wall_ccd/main.odin">Loading…</code></pre></details></figure>

<figure data-example="cameras"><video src="videos/cameras.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>cameras<span class="desc">Cameras controller.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/cameras/main.odin">Loading…</code></pre></details></figure>

<figure data-example="crowd_nav"><video src="videos/crowd_nav.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>crowd_nav<span class="desc">Detour crowd agents navigating a navmesh.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/crowd_nav/main.odin">Loading…</code></pre></details></figure>

<figure data-example="debug_draw"><video src="videos/debug_draw.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>debug_draw<span class="desc">Debug draw</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/debug_draw/main.odin">Loading…</code></pre></details></figure>

<figure data-example="forcefield"><video src="videos/forcefield.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>forcefield<span class="desc">GUse forcefield to influence particles.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/forcefield/main.odin">Loading…</code></pre></details></figure>

<figure data-example="gltf_animation"><video src="videos/gltf_animation.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>gltf_animation<span class="desc">Skinned glTF playback.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/gltf_animation/main.odin">Loading…</code></pre></details></figure>

<figure data-example="gltf_static"><video src="videos/gltf_static.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>gltf_static<span class="desc">Basic glTF asset.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/gltf_static/main.odin">Loading…</code></pre></details></figure>

<figure data-example="grid"><video src="videos/grid.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>grid<span class="desc">Spawning and despawning nodes</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/grid/main.odin">Loading…</code></pre></details></figure>

<figure data-example="ik"><video src="videos/ik.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>ik<span class="desc">Basic FABRIK.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/ik/main.odin">Loading…</code></pre></details></figure>

<figure data-example="input_demo"><video src="videos/input_demo.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>input_demo<span class="desc">Keyboard, mouse event plumbing.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/input_demo/main.odin">Loading…</code></pre></details></figure>

<figure data-example="jump"><video src="videos/jump.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>jump<span class="desc">Character controller and jump.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/jump/main.odin">Loading…</code></pre></details></figure>

<figure data-example="lights"><video src="videos/lights.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>lights<span class="desc">Point, spot, directional lights + shadows.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/lights/main.odin">Loading…</code></pre></details></figure>

<figure data-example="material"><video src="videos/material.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>material<span class="desc">PBR material parameter sweep.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/material/main.odin">Loading…</code></pre></details></figure>

<figure data-example="navmesh"><video src="videos/navmesh.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>navmesh<span class="desc">Recast build + Detour pathfinding overlay.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/navmesh/main.odin">Loading…</code></pre></details></figure>

<figure data-example="obj_loader"><video src="videos/obj_loader.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>obj_loader<span class="desc">Wavefront OBJ import.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/obj_loader/main.odin">Loading…</code></pre></details></figure>

<figure data-example="orthographic_camera"><video src="videos/orthographic_camera.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>orthographic_camera<span class="desc">Orthographic projection setup.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/orthographic_camera/main.odin">Loading…</code></pre></details></figure>

<figure data-example="particles"><video src="videos/particles.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>particles<span class="desc">Compute-driven particle system.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/particles/main.odin">Loading…</code></pre></details></figure>

<figure data-example="path_modifier"><video src="videos/path_modifier.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>path_modifier<span class="desc">Procedural bone modifier following a spline.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/path_modifier/main.odin">Loading…</code></pre></details></figure>

<figure data-example="pbr"><video src="videos/pbr.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>pbr<span class="desc">IBL + PBR showcase.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/pbr/main.odin">Loading…</code></pre></details></figure>

<figure data-example="physics"><video src="videos/physics.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>physics<span class="desc">Basic rigid body physics</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/physics/main.odin">Loading…</code></pre></details></figure>

<figure data-example="post_process"><video src="videos/post_process.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>post_process<span class="desc">Bloom, DoF, fog, tonemap, outline, crosshatch.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/post_process/main.odin">Loading…</code></pre></details></figure>

<figure data-example="procedural_mesh"><video src="videos/procedural_mesh.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>procedural_mesh<span class="desc">Mesh generated at runtime.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/procedural_mesh/main.odin">Loading…</code></pre></details></figure>

<figure data-example="render_to_texture"><video src="videos/render_to_texture.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>render_to_texture<span class="desc">Render to texture</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/render_to_texture/main.odin">Loading…</code></pre></details></figure>

<figure data-example="scene_graph"><video src="videos/scene_graph.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>scene_graph<span class="desc">Hierarchical transforms and traversal.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/scene_graph/main.odin">Loading…</code></pre></details></figure>

<figure data-example="spider_leg_modifier"><video src="videos/spider_leg_modifier.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>spider_leg_modifier<span class="desc">Procedurally generated spider legs.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/spider_leg_modifier/main.odin">Loading…</code></pre></details></figure>

<figure data-example="spline"><video src="videos/spline.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>spline<span class="desc">Spline evaluation and visualization.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/spline/main.odin">Loading…</code></pre></details></figure>

<figure data-example="sprite"><video src="videos/sprite.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>sprite<span class="desc">2D sprite batching.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/sprite/main.odin">Loading…</code></pre></details></figure>

<figure data-example="tail_modifier"><video src="videos/tail_modifier.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>tail_modifier<span class="desc">Procedural tail follow-through modifier.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/tail_modifier/main.odin">Loading…</code></pre></details></figure>

<figure data-example="transparent"><video src="videos/transparent.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>transparent<span class="desc">Order-dependent transparency pass.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/transparent/main.odin">Loading…</code></pre></details></figure>

<figure data-example="ui"><video src="videos/ui.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>ui<span class="desc">2D UI widgets, layout, events, fontstash text.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/ui/main.odin">Loading…</code></pre></details></figure>

<figure data-example="wireframe"><video src="videos/wireframe.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>wireframe<span class="desc">Wireframe rendering pipeline.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/wireframe/main.odin">Loading…</code></pre></details></figure>

<figure data-example="snake"><video src="videos/snake.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>snake<span class="desc">Snake game in 3D.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/snake/main.odin">Loading…</code></pre></details></figure>

<figure data-example="torus_tetris"><video src="videos/torus_tetris.mp4" autoplay muted loop playsinline preload="metadata"></video><figcaption>torus_tetris<span class="desc">Tetris in 3D.</span></figcaption><details><summary>Show code</summary><pre><code class="language-odin" data-src="https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/torus_tetris/main.odin">Loading…</code></pre></details></figure>

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

// lazy-fetch example source on first <details> open
document.querySelectorAll('.example-grid details').forEach(d => {
  d.addEventListener('toggle', async () => {
    if (!d.open) return;
    const code = d.querySelector('code[data-src]');
    if (!code || code.dataset.loaded) return;
    const url = code.dataset.src;
    try {
      const r = await fetch(url);
      if (!r.ok) throw new Error(r.status + ' ' + r.statusText);
      code.textContent = await r.text();
      code.dataset.loaded = '1';
    } catch (e) {
      code.textContent = 'failed to load source: ' + e.message + '\n' + url;
    }
  });
});
</script>
