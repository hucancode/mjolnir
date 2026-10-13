<script>
  import { onMount } from 'svelte';
  import { base } from '$app/paths';
  import * as THREE from 'three';
  import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
  import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

  const pbrFeatures = ['Albedo', 'Specular', 'Emissive'];

  let wrap, box, canvas;
  let failed = $state(false);
  let enabled = $state(0); // number of PBR features currently on
  let boxStyle = $state('left:0;width:100%');

  const smooth = (a, b, x) => {
    const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  };

  // scroll timeline, in viewport heights from the top of the showcase
  const T = { light: [0.4, 1.2], albedo: 2.3, specular: 3.0, emissive: 3.6, anim: [4.2, 4.9] };

  onMount(() => {
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    let renderer;
    try {
      renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
    } catch {
      failed = true;
      return;
    }
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    renderer.shadowMap.enabled = true;

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 100);
    camera.position.set(3.2, 3.4, 4.4);
    camera.lookAt(0, 0.9, 0);

    const grid = new THREE.GridHelper(12, 24, dark ? 0x8899cc : 0x333355, dark ? 0x445577 : 0xaaaabb);
    grid.material.transparent = true;
    scene.add(grid);

    const ground = new THREE.Mesh(
      new THREE.PlaneGeometry(14, 14),
      new THREE.MeshStandardMaterial({ color: dark ? 0x30303c : 0xdcdce4, transparent: true, opacity: 0 })
    );
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);

    const ambient = new THREE.AmbientLight(0xffffff, 0);
    const sun = new THREE.DirectionalLight(0xffffff, 0);
    sun.position.set(3, 5, 3);
    sun.castShadow = true;
    sun.shadow.mapSize.set(1024, 1024);
    Object.assign(sun.shadow.camera, { left: -3, right: 3, top: 3, bottom: -3, near: 1, far: 15 });
    scene.add(ambient, sun);

    const pmrem = new THREE.PMREMGenerator(renderer);
    const env = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

    const wireMat = new THREE.MeshBasicMaterial({ wireframe: true, color: dark ? 0xa5b4fc : 0x222244 });
    const solidMat = new THREE.MeshStandardMaterial({ color: 0xb8b8c4, roughness: 0.8 });

    let lastKey = '';
    let model, mixer, idle;
    const meshes = []; // { mesh, pbr, maps }
    new GLTFLoader().load(`${base}/models/Warrior.glb`, (gltf) => {
      model = gltf.scene;
      const box3 = new THREE.Box3().setFromObject(model);
      const size = box3.getSize(new THREE.Vector3());
      const s = 2 / size.y;
      model.scale.setScalar(s);
      model.position.set(-(box3.min.x + size.x / 2) * s, -box3.min.y * s, -(box3.min.z + size.z / 2) * s);
      model.traverse((o) => {
        if (!o.isMesh) return;
        o.castShadow = true;
        o.frustumCulled = false;
        const pbr = o.material;
        meshes.push({
          mesh: o,
          pbr,
          maps: {
            map: pbr.map,
            emissiveMap: pbr.emissiveMap,
            specularColorMap: pbr.specularColorMap,
            specularIntensity: pbr.specularIntensity,
            roughness: pbr.roughness
          }
        });
      });
      scene.add(model);
      lastKey = ''; // force materials to be applied now that meshes exist
      mixer = new THREE.AnimationMixer(model);
      const clip = THREE.AnimationClip.findByName(gltf.animations, 'idle') ?? gltf.animations[0];
      if (clip) {
        idle = mixer.clipAction(clip);
        idle.setEffectiveWeight(0);
        idle.play();
      }
    }, undefined, () => (failed = true));

    function applyMaterials(light, t) {
      const pbrOn = t >= T.albedo;
      for (const m of meshes) {
        let mat;
        if (pbrOn) {
          mat = m.pbr;
          const spec = t >= T.specular;
          const emit = t >= T.emissive;
          mat.map = m.maps.map;
          mat.specularColorMap = spec ? m.maps.specularColorMap : null;
          mat.specularIntensity = spec ? m.maps.specularIntensity : 0;
          mat.roughness = spec ? m.maps.roughness : 1;
          mat.emissiveMap = emit ? m.maps.emissiveMap : null;
          mat.emissive.setScalar(emit ? 1 : 0);
          mat.needsUpdate = true;
        } else {
          mat = light > 0.5 ? solidMat : wireMat;
        }
        m.mesh.material = mat;
      }
      scene.environment = pbrOn ? env : null;
      const n = t >= T.emissive ? 3 : t >= T.specular ? 2 : pbrOn ? 1 : 0;
      if (n !== enabled) enabled = n;
    }

    let t = 0;
    function readScroll() {
      const vh = innerHeight;
      t = Math.max(0, -wrap.getBoundingClientRect().top / vh);
    }

    function resize() {
      const w = box.clientWidth, h = box.clientHeight;
      if (!w || !h) return;
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
    }

    const clock = new THREE.Clock();
    let visible = true, raf = 0;
    function frame() {
      raf = requestAnimationFrame(frame);
      readScroll();
      const light = smooth(T.light[0], T.light[1], t);
      const anim = smooth(T.anim[0], T.anim[1], t);
      const w = 1 - 0.5 * light;
      boxStyle = `left:${(1 - w) * 100}%;width:${w * 100}%`;
      resize();
      grid.material.opacity = 1 - light;
      ground.material.opacity = light;
      ambient.intensity = 0.5 * light;
      sun.intensity = 2.5 * light;
      const key = `${light > 0.5}|${t >= T.albedo}|${t >= T.specular}|${t >= T.emissive}`;
      if (key !== lastKey) {
        lastKey = key;
        applyMaterials(light, t);
      }
      const dt = clock.getDelta();
      if (idle) idle.setEffectiveWeight(anim);
      if (mixer && anim > 0) mixer.update(dt);
      renderer.render(scene, camera);
    }
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !visible) { visible = true; clock.getDelta(); frame(); }
      else if (!e.isIntersecting && visible) { visible = false; cancelAnimationFrame(raf); }
    });
    io.observe(wrap);
    frame();

    return () => {
      cancelAnimationFrame(raf);
      io.disconnect();
      pmrem.dispose();
      renderer.dispose();
    };
  });
</script>

{#if failed}
  <h1>Mjolnir Engine</h1>
  <p>
    <a href="https://github.com/hucancode/mjolnir">Mjolnir</a> is a minimalistic, bindless,
    GPU-driven game engine in Odin + Vulkan 1.3.
  </p>
  <img class="hero" src="{base}/images/pp.png" alt="Post-process example" />
{:else}
  <div class="showcase" bind:this={wrap}>
    <div class="stage">
      <div class="canvas-box" bind:this={box} style={boxStyle}>
        <canvas bind:this={canvas}></canvas>
      </div>
      <ul class="pbr-flags" class:on={enabled > 0}>
        {#each pbrFeatures as f, i}
          <li class:active={i < enabled}>{f}</li>
        {/each}
      </ul>
    </div>
    <section class="step" style="height:100vh">
      <h1>Mjolnir Engine</h1>
      <p>
        <a href="https://github.com/hucancode/mjolnir">Mjolnir</a> is a minimalistic, bindless,
        GPU-driven game engine in Odin + Vulkan 1.3.
      </p>
    </section>
    <section class="step" style="height:100vh">
      <h2>Lights and shadows</h2>
      <p>Point, spot and directional lights with 2D and cubemap shadow maps.</p>
      <a href="{base}/examples#lights">See <code>lights</code></a>
    </section>
    <section class="step" style="height:250vh">
      <h2>Physically-based rendering</h2>
      <p>
        Metallic-roughness materials with image-based lighting, driven entirely from bindless
        GPU buffers. Scroll to enable material features one at a time.
      </p>
      <a href="{base}/examples#pbr">See <code>pbr</code></a>
    </section>
    <section class="step" style="height:150vh">
      <h2>Skeletal animation</h2>
      <p>Forward kinematics, FABRIK inverse kinematics, and layering with bone masks, blend modes and transitions.</p>
      <a href="{base}/examples#gltf_animation">See <code>gltf_animation</code></a>
    </section>
  </div>
{/if}
