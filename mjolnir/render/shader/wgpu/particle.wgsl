// Particles drawn in the forward pass: a camera-facing quad (six vertices) per alive particle,
// instanced (WebGPU points are one pixel), sized in pixels as the Vulkan point size. Textures
// come from the PARTICLES group: slot j holds the texture handle u.textures[j].

struct Particle {
    position: vec3f,
    size_start: f32,
    velocity: vec3f,
    size_end: f32,
    color_start: vec4f,
    color_end: vec4f,
    life: f32,
    max_life: f32,
    weight: f32,
    texture_index: u32,
}

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
// the indirect draw header (4 words), then the alive particles' indices
@group(0) @binding(2) var<storage, read> alive: array<u32>;

@group(1) @binding(0) var texture0: texture_2d<f32>;
@group(1) @binding(1) var texture1: texture_2d<f32>;
@group(1) @binding(2) var texture2: texture_2d<f32>;
@group(1) @binding(3) var texture3: texture_2d<f32>;
@group(1) @binding(4) var texture4: texture_2d<f32>;
@group(1) @binding(5) var texture5: texture_2d<f32>;
@group(1) @binding(6) var texture6: texture_2d<f32>;
@group(1) @binding(7) var texture7: texture_2d<f32>;

struct ParticleDrawPush {
    camera_index: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    // the texture handle each slot of the group holds
    textures: array<vec4u, 2>,
}
@group(2) @binding(0) var<uniform> u: ParticleDrawPush;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) color: vec4f,
    // gl_PointCoord: 0 at the quad's top left
    @location(1) uv: vec2f,
    @location(2) @interpolate(flat) texture_index: u32,
}

const ALIVE_HEADER: u32 = 4u;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance: u32) -> VertexOut {
    var corners = array(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0), vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(-1.0, 1.0));
    let corner = corners[vertex_index];
    let p = particles[alive[ALIVE_HEADER + instance]];
    let camera = views[u.camera_index];
    let ratio = p.life / p.max_life;
    let size = mix(p.size_end, p.size_start, ratio);
    let dist = clamp(length(camera.position.xyz - p.position), 1.0, 20.0);
    // the Vulkan point size: the quad's side in pixels
    let pixels = clamp(size / dist, 10.0, 100.0);
    var clip = camera.projection * camera.view * vec4f(p.position, 1.0);
    // Vulkan clip space: +y is down the screen, as uv
    clip = vec4f(clip.xy + corner * pixels / camera.extent * clip.w, clip.zw);
    var out: VertexOut;
    out.clip = clip_output(clip);
    out.color = mix(p.color_end, p.color_start, ratio);
    out.uv = corner * 0.5 + 0.5;
    out.texture_index = p.texture_index;
    return out;
}

// Alpha of the particle's texture at uv: 1 without one, or past the group's slots.
fn texture_alpha(handle: u32, uv: vec2f) -> f32 {
    if (handle == NO_TEXTURE) { return 1.0; }
    var slot = 8u;
    for (var j = 0u; j < 8u; j++) {
        if (u.textures[j / 4u][j % 4u] == handle) {
            slot = j;
            break;
        }
    }
    switch (slot) {
        case 0u: { return textureSampleLevel(texture0, linear_repeat, uv, 0.0).a; }
        case 1u: { return textureSampleLevel(texture1, linear_repeat, uv, 0.0).a; }
        case 2u: { return textureSampleLevel(texture2, linear_repeat, uv, 0.0).a; }
        case 3u: { return textureSampleLevel(texture3, linear_repeat, uv, 0.0).a; }
        case 4u: { return textureSampleLevel(texture4, linear_repeat, uv, 0.0).a; }
        case 5u: { return textureSampleLevel(texture5, linear_repeat, uv, 0.0).a; }
        case 6u: { return textureSampleLevel(texture6, linear_repeat, uv, 0.0).a; }
        case 7u: { return textureSampleLevel(texture7, linear_repeat, uv, 0.0).a; }
        default: { return 1.0; }
    }
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let color = vec4f(in.color.rgb, texture_alpha(in.texture_index, in.uv) * in.color.a);
    if (color.a < 0.01) {
        discard;
    }
    return color;
}
