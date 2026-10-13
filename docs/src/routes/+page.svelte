<script>
  import { base } from '$app/paths';
  import Showcase from '$lib/Showcase.svelte';

  const features = [
    { title: 'Cameras as render targets', text: 'Any camera output can be sampled as a texture: mirrors, minimaps, portals.', example: 'render_to_texture' },
    { title: 'Skeletal animation', text: 'Forward kinematics, FABRIK inverse kinematics, and layering with bone masks, blend modes and transitions.', example: 'animation_layering' },
    { title: 'Procedural animation', text: 'Tail follow-through, spider legs and path-on-spline modifiers on top of any rig.', example: 'spider_leg_modifier' },
    { title: 'Rigid-body physics', text: 'Boxes, spheres and cylinders with sleeping, sensors, area queries and ray casts. Continuous collision keeps fast bodies from tunneling through thin walls.', example: 'bullet_wall_ccd' },
    { title: 'Navigation', text: 'Recast navmesh baking, Detour path queries and crowd steering with local avoidance.', example: 'crowd_nav' },
    { title: 'Particles and force fields', text: 'GPU particle simulation, shaped by force fields placed in the scene.', example: 'particles' },
    { title: '2D UI', text: 'Flex layout, anchors, text wrap, clipping and scrolling, with hit testing and TTF/OTF text.', example: 'ui' },
    { title: 'Post-processing', text: 'Tonemap, bloom, blur, fog, outline, depth of field and crosshatch, stacked per camera.', example: 'post_process' },
    { title: 'Billboards, sprites, splines and tweens', text: 'The small pieces games reach for first.', example: 'sprite' }
  ];
</script>

<svelte:head><title>Mjolnir Engine</title></svelte:head>

<Showcase />

<section class="features">
  {#each features as f, i (f.title)}
    <article class:flip={i % 2 === 1}>
      <div class="text">
        <h2>{f.title}</h2>
        <p>{f.text}</p>
        <a href="{base}/examples#{f.example}">See <code>{f.example}</code></a>
      </div>
      <div class="art">
        <video src="{base}/videos/{f.example}.mp4" autoplay muted loop playsinline preload="none"></video>
      </div>
    </article>
  {/each}
</section>
