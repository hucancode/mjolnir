// The vertex shader of the lighting pipelines (scene group LIGHTING, texture group LIGHTING):
// a light's volume mesh for point and spot, a far-plane triangle over the screen otherwise.

override LIGHT_TYPE: u32 = 0u;

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> lights: array<Light>;

@group(1) @binding(0) var normal_texture: texture_2d<f32>;
@group(1) @binding(1) var albedo_texture: texture_2d<f32>;
@group(1) @binding(2) var metallic_roughness_texture: texture_2d<f32>;
@group(1) @binding(3) var emissive_texture: texture_2d<f32>;
@group(1) @binding(4) var depth_texture: texture_depth_2d;
@group(1) @binding(5) var shadow_maps: texture_depth_2d_array;
@group(1) @binding(6) var irradiance_cube: texture_cube<f32>;
@group(1) @binding(7) var prefilter_cube: texture_cube<f32>;
@group(1) @binding(8) var brdf_lut: texture_2d<f32>;
@group(1) @binding(9) var environment_map: texture_2d<f32>;

struct LightingUniforms {
    camera_index: u32,
    skybox_intensity: f32,
    skybox_blur: f32,
    // the environment map and the IBL cubes are bound
    has_environment: u32,
    has_ibl: u32,
}
@group(2) @binding(0) var<uniform> u: LightingUniforms;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) @interpolate(flat) light: u32,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance: u32, @location(0) a_position: vec3f) -> VertexOut {
    var out: VertexOut;
    out.light = instance;
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL || LIGHT_TYPE == LIGHT_AMBIENT) {
        // no volume: a clip-space triangle covering the screen on the far plane, directional
        // lights depth-testing it to skip the background
        let corner = vec2f(select(-1.0, 3.0, vertex_index == 2u), select(-1.0, 3.0, vertex_index == 1u));
        out.clip = clip_output(vec4f(corner, 1.0, 1.0));
        return out;
    }
    let light = lights[instance];
    let camera = views[u.camera_index];
    var world_position: vec3f;
    if (LIGHT_TYPE == LIGHT_POINT) {
        // unit sphere scaled to the light radius
        world_position = light.position + a_position * light.radius;
    } else {
        // unit cone (height 1 along +Y, base radius 1) flipped so its tip sits at the light
        // and its base covers the outer angle at `radius`
        let tana = tan(min(light.angle_outer, PI * 0.45));
        let xz_scale = light.radius * tana * 2.0;
        let scaled = vec3f(a_position.x * xz_scale, (a_position.y - 0.5) * -light.radius, a_position.z * xz_scale);
        let up = light.direction;
        let forward = select(vec3f(1.0, 0.0, 0.0), normalize(cross(vec3f(0.0, 1.0, 0.0), up)), abs(up.y) < 0.9);
        let right = cross(up, forward);
        world_position = light.position + mat3x3f(right, up, forward) * scaled;
    }
    out.clip = clip_output(camera.projection * camera.view * vec4f(world_position, 1.0));
    return out;
}

// World position of the G-buffer texel at framebuffer uv, rebuilt from its depth. Vulkan's
// clip-space y points down, so ndc follows uv on both axes.
fn world_position(camera: View, uv: vec2f, depth: f32) -> vec3f {
    let p = camera.inv_view_projection * vec4f(uv * 2.0 - 1.0, depth, 1.0);
    return p.xyz / p.w;
}

fn scene_depth(pixel: vec2i) -> f32 {
    return textureLoad(depth_texture, pixel, 0);
}
