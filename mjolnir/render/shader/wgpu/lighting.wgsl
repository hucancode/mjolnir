// Deferred lighting, tiled (scene group LIGHTING, texture group LIGHTING, group 3 the lit
// image): a group shades a TILE x TILE tile of the camera's image. It finds the tile's depth
// range, lists the point and spot lights whose sphere meets the tile's box, then each
// invocation shades its pixel once: image-based ambient and emissive, every directional light,
// the listed lights. The background gets the skybox, or black. Lights are sorted by type
// (scene.odin pack_lights): u.light_count gives each type's range, the ambient light last.

const TILE: u32 = 16u;
const MAX_LIGHTS: u32 = 256u;
// texels on a side of a shadow map; the atlas holds them as tiles, a row of
// textureDimensions(shadow_maps).x / SHADOW_MAP_SIZE (pass_shadow.odin shadow_tile)
const SHADOW_MAP_SIZE: f32 = 512.0;

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> lights: array<Light>;

@group(1) @binding(0) var normal_texture: texture_2d<f32>;
@group(1) @binding(1) var albedo_texture: texture_2d<f32>;
@group(1) @binding(2) var metallic_roughness_texture: texture_2d<f32>;
@group(1) @binding(3) var emissive_texture: texture_2d<f32>;
@group(1) @binding(4) var depth_texture: texture_depth_2d;
@group(1) @binding(5) var shadow_maps: texture_depth_2d;
@group(1) @binding(6) var irradiance_cube: texture_cube<f32>;
@group(1) @binding(7) var prefilter_cube: texture_cube<f32>;
@group(1) @binding(8) var brdf_lut: texture_2d<f32>;
@group(1) @binding(9) var environment_map: texture_2d<f32>;

struct LightingUniforms {
    camera_index: u32,
    // texture handles; a bindless shader indexes with them, here only whether there is one
    irradiance: u32,
    prefilter: u32,
    brdf_lut: u32,
    environment: u32,
    skybox_intensity: f32,
    skybox_blur: f32,
    // the bindless storage image of the lit image; group 3 holds it here
    output_index: u32,
    // by LightType: point, spot, directional, ambient
    light_count: vec4u,
}
@group(2) @binding(0) var<uniform> u: LightingUniforms;

@group(3) @binding(0) var output_image: texture_storage_2d<rgba16float, write>;

var<workgroup> tile_min_bits: atomic<u32>;
var<workgroup> tile_max_bits: atomic<u32>;
var<workgroup> tile_light_count: atomic<u32>;
var<workgroup> tile_lights: array<u32, MAX_LIGHTS>;

// shadow_face past the last cascade
const NO_FACE: u32 = 0xFFFFFFFFu;
// light reaching a fragment: 1 when lit, SHADOW_FLOOR when fully occluded
const SHADOW_FLOOR: f32 = 0.1;
// shadow texels from a lookup to the farthest texel its filter reads: a 3x3 grid of 2x2
// compare taps
const SHADOW_FILTER_RADIUS: f32 = 2.0;
// cascades of a directional light's map, SHADOW_CASCADES in scene.odin
const SHADOW_CASCADES: u32 = 4u;

// World position of the G-buffer texel at framebuffer uv, rebuilt from its depth. Vulkan's
// clip-space y points down, so ndc follows uv on both axes.
fn world_position(camera: View, uv: vec2f, depth: f32) -> vec3f {
    let p = camera.inv_view_projection * vec4f(uv * 2.0 - 1.0, depth, 1.0);
    return p.xyz / p.w;
}

fn scene_depth(pixel: vec2i) -> f32 {
    return textureLoad(depth_texture, pixel, 0);
}

// Difference of world positions across `pixel` along `axis`, taken towards the neighbor
// nearer in depth so a silhouette doesn't bend it.
fn surface_step(camera: View, pixel: vec2i, axis: vec2i, frag_pos: vec3f, depth: f32) -> vec3f {
    let hi = min(pixel + axis, vec2i(camera.extent) - 1);
    let lo = max(pixel - axis, vec2i(0));
    let hi_depth = scene_depth(hi);
    let lo_depth = scene_depth(lo);
    if (all(lo == pixel) || (any(hi != pixel) && abs(hi_depth - depth) <= abs(lo_depth - depth))) {
        return world_position(camera, (vec2f(hi) + 0.5) / camera.extent, hi_depth) - frag_pos;
    }
    return frag_pos - world_position(camera, (vec2f(lo) + 0.5) / camera.extent, lo_depth);
}

// Normal of the rasterized surface at `pixel`, rebuilt from the depth buffer and facing the
// camera: unlike the G-buffer normal, neither normal maps nor smooth shading tilt it off the
// surface the shadow map recorded. `fallback` where the surface is degenerate.
fn geometric_normal(camera: View, pixel: vec2i, frag_pos: vec3f, depth: f32, fallback: vec3f) -> vec3f {
    let c = cross(surface_step(camera, pixel, vec2i(1, 0), frag_pos, depth), surface_step(camera, pixel, vec2i(0, 1), frag_pos, depth));
    let len = length(c);
    if (len < 1e-12) {
        return fallback;
    }
    let n = c / len;
    return select(n, -n, dot(n, camera.position.xyz - frag_pos) < 0.0);
}

// Direction from the fragment towards the light.
fn light_direction(light: Light, light_type: u32, frag_pos: vec3f) -> vec3f {
    if (light_type == LIGHT_DIRECTIONAL) {
        return -light.direction;
    }
    return normalize(light.position - frag_pos);
}

// The shadow face seen from the light towards p: the cube face on the major axis of the
// light-to-p direction (+X, -X, +Y, -Y, +Z, -Z) for a point light, the finest cascade whose
// box holds p, with room for the filter, for a directional light (NO_FACE beyond the last),
// the only face otherwise.
fn shadow_face(light: Light, light_type: u32, p: vec3f) -> u32 {
    if (light_type == LIGHT_DIRECTIONAL) {
        // the normal offset moves p up to SHADOW_FILTER_RADIUS + 0.5 texels
        let edge = 1.0 - 2.0 * (2.0 * SHADOW_FILTER_RADIUS + 0.5) / SHADOW_MAP_SIZE;
        for (var c = 0u; c < SHADOW_CASCADES; c++) {
            let s = views[light.shadow_map + c].view_projection * vec4f(p, 1.0);
            // a cascade's box is no deeper than wide: with the light along the view, far
            // points project into the near cascades too
            if (abs(s.x) < edge && abs(s.y) < edge && s.z > 0.0 && s.z < 1.0) {
                return c;
            }
        }
        return NO_FACE;
    }
    if (light_type != LIGHT_POINT) {
        return 0u;
    }
    let d = p - light.position;
    let a = abs(d);
    if (a.x >= a.y && a.x >= a.z) {
        return select(1u, 0u, d.x >= 0.0);
    }
    if (a.y >= a.z) {
        return select(3u, 2u, d.y >= 0.0);
    }
    return select(5u, 4u, d.z >= 0.0);
}

// World size of a shadow texel of `view` at frag_pos: constant for an orthographic map, read
// from its projection, growing with view depth for a perspective one.
fn shadow_texel(light: Light, light_type: u32, frag_pos: vec3f, view: View) -> f32 {
    let d = frag_pos - light.position;
    if (light_type == LIGHT_POINT) {
        let a = abs(d);
        return light.shadow_texel * max(a.x, max(a.y, a.z));
    }
    if (light_type == LIGHT_SPOT) {
        return light.shadow_texel * max(dot(d, light.direction), 0.0);
    }
    return 2.0 / (view.projection[0][0] * SHADOW_MAP_SIZE);
}

// Depth test of frag_pos against its shadow face, filtered over a 3x3 grid of 2x2 compare
// taps. The lookup moves off the surface along its geometric normal n, further the more the
// surface turns from the light direction l, so the filter's texels all lie in front of it.
// The face's view projects it into its atlas tile (clip y = -1 is texel row 0); taps are
// clamped to the tile, as an array layer's edge would clamp them.
fn calculate_shadow(light: Light, light_type: u32, frag_pos: vec3f, n: vec3f, l: vec3f) -> f32 {
    if (light.shadow_map == 0u) {
        return 1.0;
    }
    let cos_theta = clamp(dot(n, l), 0.0, 1.0);
    let sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    let offset = 0.5 + SHADOW_FILTER_RADIUS * sin_theta;
    var p = frag_pos;
    var face: u32;
    if (light_type == LIGHT_DIRECTIONAL) {
        // the cascade sets the texel size, so pick it before the offset
        face = shadow_face(light, light_type, p);
        if (face == NO_FACE) {
            return 1.0;
        }
        p += n * (offset * shadow_texel(light, light_type, p, views[light.shadow_map + face]));
    } else {
        // the texel size doesn't depend on the face; the offset may cross one
        p += n * (offset * shadow_texel(light, light_type, p, views[light.shadow_map]));
        face = shadow_face(light, light_type, p);
    }
    let view = views[light.shadow_map + face];
    let light_space = view.view_projection * vec4f(p, 1.0);
    let coord = light_space.xyz / light_space.w;
    let uv = coord.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 1.0;
    }
    let reference = clamp(coord.z, 0.0, 1.0);
    let atlas = vec2f(textureDimensions(shadow_maps));
    let columns = u32(atlas.x / SHADOW_MAP_SIZE);
    let origin = vec2f(f32(view.layer % columns), f32(view.layer / columns)) * SHADOW_MAP_SIZE;
    let lo = (origin + 0.5) / atlas;
    let hi = (origin + SHADOW_MAP_SIZE - 0.5) / atlas;
    var lit = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let tap = (origin + uv * SHADOW_MAP_SIZE + vec2f(f32(x), f32(y))) / atlas;
            lit += textureSampleCompareLevel(shadow_maps, shadow_compare, clamp(tap, lo, hi), reference);
        }
    }
    return mix(SHADOW_FLOOR, 1.0, lit / 9.0);
}

fn attenuation(light: Light, light_type: u32, frag_pos: vec3f) -> f32 {
    if (light_type == LIGHT_DIRECTIONAL) {
        return 1.0;
    }
    if (light_type == LIGHT_POINT) {
        let norm_dist = length(light.position - frag_pos) / max(0.01, light.radius);
        return light.radius * (1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0));
    }
    let tip_to_frag = frag_pos - light.position;
    let axis = light.direction;
    let along = dot(tip_to_frag, axis);
    let radial = length(tip_to_frag - along * axis);
    let cone_radius = along * tan(light.angle_outer);
    let normalized_radial = radial / max(cone_radius, 0.001);
    let inner_outer_ratio = tan(light.angle_inner) / tan(light.angle_outer);
    var spot = smoothstep(1.0, inner_outer_ratio, normalized_radial);
    let norm_dist = along / max(0.01, light.radius);
    spot *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    return light.radius * spot;
}

// The surface a pixel shows, as the lights read it.
struct Surface {
    position: vec3f,
    // shading normal, from the G-buffer
    normal: vec3f,
    // geometric_normal, for the shadow lookup
    geometric: vec3f,
    v: vec3f,
    albedo: vec3f,
    metallic: f32,
    roughness: f32,
}

// Cook-Torrance BRDF of one light, shadowed.
fn direct_light(light: Light, light_type: u32, s: Surface) -> vec3f {
    let l = light_direction(light, light_type, s.position);
    // facing away or out of reach, the BRDF is zero: skip the shadow lookup
    if (dot(s.normal, l) <= 0.0) {
        return vec3f(0.0);
    }
    let atten = attenuation(light, light_type, s.position);
    if (atten <= 0.0) {
        return vec3f(0.0);
    }
    let f0 = mix(vec3f(0.04), s.albedo, s.metallic);
    let light_color = light.color.rgb * light.color.a;
    let h = normalize(s.v + l);
    let n_dot_l = max(dot(s.normal, l), 0.0);
    let n_dot_v = max(dot(s.normal, s.v), 0.01);
    let n_dot_h = max(dot(s.normal, h), 0.0);
    let alpha = s.roughness * s.roughness;
    let alpha2 = alpha * alpha;
    let denom = max(n_dot_h * n_dot_h * (alpha2 - 1.0) + 1.0, 0.001);
    let ndf = alpha2 / (PI * denom * denom);
    let k = pow(s.roughness + 1.0, 2.0) / 8.0;
    var g = n_dot_l / (n_dot_l * (1.0 - k) + k);
    g *= n_dot_v / (n_dot_v * (1.0 - k) + k);
    let f = f0 + (1.0 - f0) * pow(1.0 - max(dot(h, s.v), 0.0), 5.0);
    let spec = ndf * g * f / (4.0 * n_dot_v * n_dot_l + 0.01);
    let ks = clamp(f, vec3f(0.0), vec3f(1.0));
    let kd = (vec3f(1.0) - ks) * (1.0 - s.metallic);
    let direct = (kd * s.albedo / PI + spec) * light_color * n_dot_l * atten;
    return direct * calculate_shadow(light, light_type, s.position, s.geometric, l);
}

fn prefilter_max_lod() -> f32 {
    return f32(textureNumLevels(prefilter_cube) - 1u);
}

fn fresnel_schlick_roughness(cos_theta: f32, f0: vec3f, roughness: f32) -> vec3f {
    return f0 + (max(vec3f(1.0 - roughness), f0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn dir_to_equirect_uv(dir: vec3f) -> vec2f {
    let u = atan2(dir.z, dir.x) / (2.0 * PI) + 0.5;
    let v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
    return vec2f(u, v);
}

fn sample_skybox(camera: View, uv: vec2f) -> vec3f {
    let ndc = uv * 2.0 - 1.0;
    let world_far = camera.inv_view_projection * vec4f(ndc, 1.0, 1.0);
    let dir = normalize(world_far.xyz / world_far.w - camera.position.xyz);
    let blur = clamp(u.skybox_blur, 0.0, 1.0);
    if (blur <= 0.0 || u.prefilter == 0u) {
        return textureSampleLevel(environment_map, linear_repeat, dir_to_equirect_uv(dir), 0.0).rgb;
    }
    return textureSampleLevel(prefilter_cube, linear_clamp, dir, blur * prefilter_max_lod()).rgb;
}

// Image-based lighting at intensity ibl_intensity, from the unnormalized G-buffer normal.
fn ambient_light(ibl_intensity: f32, normal: vec3f, s: Surface, roughness: f32) -> vec3f {
    if (ibl_intensity <= 0.0 || u.prefilter == 0u) {
        return vec3f(0.0);
    }
    let r = reflect(-s.v, normal);
    let n_dot_v = max(dot(normal, s.v), 0.0);
    let f0 = mix(vec3f(0.04), s.albedo, s.metallic);
    let f = fresnel_schlick_roughness(n_dot_v, f0, roughness);
    let irradiance = textureSampleLevel(irradiance_cube, linear_clamp, normal, 0.0).rgb;
    let kd = (vec3f(1.0) - f) * (1.0 - s.metallic);
    let prefiltered = textureSampleLevel(prefilter_cube, linear_clamp, r, roughness * prefilter_max_lod()).rgb;
    let brdf = textureSampleLevel(brdf_lut, linear_clamp, vec2f(n_dot_v, roughness), 0.0).rg;
    let specular = prefiltered * (f * brdf.x + brdf.y);
    return (kd * irradiance * s.albedo + specular) * ibl_intensity;
}

// Whether the sphere (center, radius) meets the box [lo, hi].
fn sphere_meets_box(center: vec3f, radius: f32, lo: vec3f, hi: vec3f) -> bool {
    let d = clamp(center, lo, hi) - center;
    return dot(d, d) <= radius * radius;
}

@compute @workgroup_size(16, 16, 1)
fn main(@builtin(global_invocation_id) gid: vec3u, @builtin(workgroup_id) group: vec3u, @builtin(local_invocation_index) local: u32) {
    let camera = views[u.camera_index];
    let extent = vec2i(camera.extent);
    let pixel = vec2i(gid.xy);
    let inside = pixel.x < extent.x && pixel.y < extent.y;

    // the tile's depth range, over the pixels that show a surface
    if (local == 0u) {
        atomicStore(&tile_min_bits, bitcast<u32>(1.0));
        atomicStore(&tile_max_bits, 0u);
        atomicStore(&tile_light_count, 0u);
    }
    workgroupBarrier();
    var depth = 1.0;
    if (inside) {
        depth = scene_depth(pixel);
    }
    // depth is positive: its bits order as it does
    if (depth < 1.0) {
        atomicMin(&tile_min_bits, bitcast<u32>(depth));
        atomicMax(&tile_max_bits, bitcast<u32>(depth));
    }
    workgroupBarrier();

    // the point and spot lights whose sphere meets the tile's box
    let depth_min = bitcast<f32>(atomicLoad(&tile_min_bits));
    let depth_max = bitcast<f32>(atomicLoad(&tile_max_bits));
    let local_lights = u.light_count.x + u.light_count.y;
    if (depth_min <= depth_max) {
        let tile_lo = vec2f(group.xy * TILE) / camera.extent;
        let tile_hi = vec2f(min(vec2i((group.xy + 1u) * TILE), extent)) / camera.extent;
        var lo = vec3f(1e30);
        var hi = vec3f(-1e30);
        for (var c = 0u; c < 8u; c++) {
            let uv = vec2f(select(tile_lo.x, tile_hi.x, (c & 1u) != 0u), select(tile_lo.y, tile_hi.y, (c & 2u) != 0u));
            let p = world_position(camera, uv, select(depth_min, depth_max, (c & 4u) != 0u));
            lo = min(lo, p);
            hi = max(hi, p);
        }
        for (var i = local; i < local_lights; i += TILE * TILE) {
            if (sphere_meets_box(lights[i].position, lights[i].radius, lo, hi)) {
                tile_lights[atomicAdd(&tile_light_count, 1u)] = i;
            }
        }
    }
    workgroupBarrier();
    let listed = atomicLoad(&tile_light_count);
    if (!inside) {
        return;
    }

    let uv = (vec2f(pixel) + 0.5) / camera.extent;
    // background (depth left at the far clear value): the skybox, if any
    if (depth >= 1.0) {
        var sky = vec3f(0.0);
        if (u.skybox_intensity > 0.0 && u.environment != 0u) {
            sky = sample_skybox(camera, uv) * u.skybox_intensity;
        }
        textureStore(output_image, pixel, vec4f(sky, 1.0));
        return;
    }
    let raw_normal = textureLoad(normal_texture, pixel, 0).xyz * 2.0 - 1.0;
    let mr = textureLoad(metallic_roughness_texture, pixel, 0).rg;
    var s: Surface;
    s.position = world_position(camera, uv, depth);
    // unfiltered: a blend across a silhouette is no surface's normal
    s.normal = normalize(raw_normal);
    s.v = normalize(camera.position.xyz - s.position);
    s.albedo = textureLoad(albedo_texture, pixel, 0).rgb;
    s.metallic = clamp(mr.r, 0.0, 1.0);
    s.geometric = geometric_normal(camera, pixel, s.position, depth, s.normal);

    let first_directional = local_lights;
    let ambient = first_directional + u.light_count.z;
    var color = textureLoad(emissive_texture, pixel, 0).rgb;
    if (u.light_count.w > 0u) {
        color += ambient_light(lights[ambient].color.a, raw_normal, s, mr.g);
    }
    s.roughness = clamp(mr.g, 0.08, 1.0);
    for (var i = first_directional; i < ambient; i++) {
        color += direct_light(lights[i], LIGHT_DIRECTIONAL, s);
    }
    for (var i = 0u; i < listed; i++) {
        let index = tile_lights[i];
        color += direct_light(lights[index], select(LIGHT_SPOT, LIGHT_POINT, index < u.light_count.x), s);
    }
    textureStore(output_image, pixel, vec4f(color, 1.0));
}
