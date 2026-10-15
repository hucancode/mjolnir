// Direct light: one draw per light type, one instance per light.

// shadow_face past the last cascade
const NO_FACE: u32 = 0xFFFFFFFFu;
// light reaching a fragment: 1 when lit, SHADOW_FLOOR when fully occluded
const SHADOW_FLOOR: f32 = 0.1;
// shadow texels from a lookup to the farthest texel its filter reads: a 3x3 grid of 2x2
// compare taps
const SHADOW_FILTER_RADIUS: f32 = 2.0;
// cascades of a directional light's map, SHADOW_CASCADES in scene.odin
const SHADOW_CASCADES: u32 = 4u;

// the light this fragment shades, read once in fs_main
var<private> light: Light;

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
fn light_direction(frag_pos: vec3f) -> vec3f {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        return -light.direction;
    }
    return normalize(light.position - frag_pos);
}

fn shadow_map_size() -> f32 {
    return f32(textureDimensions(shadow_maps).x);
}

// The shadow face seen from the light towards p: the cube face on the major axis of the
// light-to-p direction (+X, -X, +Y, -Y, +Z, -Z) for a point light, the finest cascade whose
// box holds p, with room for the filter, for a directional light (NO_FACE beyond the last),
// the only face otherwise.
fn shadow_face(p: vec3f) -> u32 {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        // the normal offset moves p up to SHADOW_FILTER_RADIUS + 0.5 texels
        let edge = 1.0 - 2.0 * (2.0 * SHADOW_FILTER_RADIUS + 0.5) / shadow_map_size();
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
    if (LIGHT_TYPE != LIGHT_POINT) {
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
fn shadow_texel(frag_pos: vec3f, view: View) -> f32 {
    let d = frag_pos - light.position;
    if (LIGHT_TYPE == LIGHT_POINT) {
        let a = abs(d);
        return light.shadow_texel * max(a.x, max(a.y, a.z));
    }
    if (LIGHT_TYPE == LIGHT_SPOT) {
        return light.shadow_texel * max(dot(d, light.direction), 0.0);
    }
    return 2.0 / (view.projection[0][0] * shadow_map_size());
}

// Depth test of frag_pos against its shadow face, filtered over a 3x3 grid of 2x2 compare
// taps. The lookup moves off the surface along its geometric normal n, further the more the
// surface turns from the light direction l, so the filter's texels all lie in front of it.
// The face's view projects it into its atlas layer (clip y = -1 is texel row 0).
fn calculate_shadow(frag_pos: vec3f, n: vec3f, l: vec3f) -> f32 {
    if (light.shadow_map == 0u) {
        return 1.0;
    }
    let cos_theta = clamp(dot(n, l), 0.0, 1.0);
    let sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    let offset = 0.5 + SHADOW_FILTER_RADIUS * sin_theta;
    var p = frag_pos;
    var face: u32;
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        // the cascade sets the texel size, so pick it before the offset
        face = shadow_face(p);
        if (face == NO_FACE) {
            return 1.0;
        }
        p += n * (offset * shadow_texel(p, views[light.shadow_map + face]));
    } else {
        // the texel size doesn't depend on the face; the offset may cross one
        p += n * (offset * shadow_texel(p, views[light.shadow_map]));
        face = shadow_face(p);
    }
    let view = views[light.shadow_map + face];
    let light_space = view.view_projection * vec4f(p, 1.0);
    var coord = light_space.xyz / light_space.w;
    let uv = coord.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 1.0;
    }
    let reference = clamp(coord.z, 0.0, 1.0);
    let texel = vec2f(1.0 / shadow_map_size());
    var lit = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            lit += textureSampleCompareLevel(shadow_maps, shadow_compare, uv + vec2f(f32(x), f32(y)) * texel, view.layer, reference);
        }
    }
    return mix(SHADOW_FLOOR, 1.0, lit / 9.0);
}

fn attenuation(frag_pos: vec3f) -> f32 {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        return 1.0;
    }
    if (LIGHT_TYPE == LIGHT_POINT) {
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

// Cook-Torrance BRDF
fn brdf(n: vec3f, v: vec3f, albedo: vec3f, roughness: f32, metallic: f32, frag_pos: vec3f) -> vec3f {
    let f0 = mix(vec3f(0.04), albedo, metallic);
    let light_color = light.color.rgb * light.color.a;
    let l = light_direction(frag_pos);
    let h = normalize(v + l);
    let n_dot_l = max(dot(n, l), 0.0);
    let n_dot_v = max(dot(n, v), 0.01);
    let n_dot_h = max(dot(n, h), 0.0);
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
    let denom = max(n_dot_h * n_dot_h * (alpha2 - 1.0) + 1.0, 0.001);
    let ndf = alpha2 / (PI * denom * denom);
    let k = pow(roughness + 1.0, 2.0) / 8.0;
    var g = n_dot_l / (n_dot_l * (1.0 - k) + k);
    g *= n_dot_v / (n_dot_v * (1.0 - k) + k);
    let f = f0 + (1.0 - f0) * pow(1.0 - max(dot(h, v), 0.0), 5.0);
    let spec = ndf * g * f / (4.0 * n_dot_v * n_dot_l + 0.01);
    let ks = clamp(f, vec3f(0.0), vec3f(1.0));
    let kd = (vec3f(1.0) - ks) * (1.0 - metallic);
    return (kd * albedo / PI + spec) * light_color * n_dot_l * attenuation(frag_pos);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    light = lights[in.light];
    let camera = views[u.camera_index];
    let uv = in.clip.xy / camera.extent;
    let pixel = vec2i(in.clip.xy);
    let depth = scene_depth(pixel);
    let frag_pos = world_position(camera, uv, depth);
    // unfiltered: a blend across a silhouette is no surface's normal
    let normal = normalize(textureLoad(normal_texture, pixel, 0).xyz * 2.0 - 1.0);
    let albedo = textureSampleLevel(albedo_texture, linear_clamp, uv, 0.0).rgb;
    let mr = textureSampleLevel(metallic_roughness_texture, linear_clamp, uv, 0.0).rg;
    let metallic = clamp(mr.r, 0.0, 1.0);
    let roughness = clamp(mr.g, 0.08, 1.0);
    let l = light_direction(frag_pos);
    // facing away, the BRDF is zero: skip the shadow lookup
    if (dot(normal, l) <= 0.0) {
        return vec4f(0.0, 0.0, 0.0, 1.0);
    }
    let v = normalize(camera.position.xyz - frag_pos);
    let surface_normal = geometric_normal(camera, pixel, frag_pos, depth, normal);
    let shadow = calculate_shadow(frag_pos, surface_normal, l);
    let direct = brdf(normal, v, albedo, roughness, metallic, frag_pos);
    return vec4f(direct * shadow, 1.0);
}
