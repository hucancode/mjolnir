// Deferred lighting, tiled: a group shades a TILE x TILE tile of the camera's image. It finds
// the tile's depth range and walks the light placements once, listing the visible placed
// lights that reach the tile: the directional lights, and the point and spot lights whose
// sphere meets the tile's box. Then each invocation shades its pixel once: image-based ambient
// and emissive, then the listed lights. The image-based light is scaled by the camera's ambient
// occlusion, when it has any. The background gets the skybox, or black. A placed light is a
// Light at a node's transform (lights.odin light_pose).
#include "common.slang"

static const uint TILE = 16;
static const uint MAX_LIGHTS = 256;
// shadowFace past the last cascade
static const uint NO_FACE = 0xFFFFFFFF;

SCENE_BUFFER(Node, nodes, 1, 2)
SCENE_BUFFER(Light, lights, 10, 1)
SCENE_BUFFER(LightPlacement, placements, 18, 3)


struct LightingPush {
    uint camera_index;
    // texture handles; Vulkan indexes with them, wgpu only checks whether there is one
    uint irradiance_index;
    uint prefilter_index;
    uint brdf_lut_index;
    uint environment_index;
    float skybox_intensity;
    float skybox_blur;
    // storage image the camera's lit image is bound at (a group on wgpu)
    uint output_index;
    // rows of the placement table
    uint light_count;
    float ibl_intensity;
    // 1: the camera's ambient occlusion image holds this frame's occlusion
    uint ambient_occlusion;
}
PUSH_BLOCK(LightingPush, lighting_push)

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D normal_texture;
[vk::binding(1, 1)] Texture2D albedo_texture;
[vk::binding(2, 1)] Texture2D metallic_roughness_texture;
[vk::binding(3, 1)] Texture2D emissive_texture;
[vk::binding(4, 1)] DepthTexture2D depth_texture;
// the shadow faces as tiles of one atlas, a row of textureDimensions(shadow_maps).x / SHADOW_MAP_SIZE
// (pass_shadow.odin shadow_tile)
[vk::binding(5, 1)] DepthTexture2D shadow_maps;
[vk::binding(6, 1)] TextureCube irradiance_cube;
[vk::binding(7, 1)] TextureCube prefilter_cube;
[vk::binding(8, 1)] Texture2D brdf_lut;
[vk::binding(9, 1)] Texture2D environment_map;
[vk::binding(10, 1)] Texture2D ambient_occlusion_texture;
[vk::binding(0, 3)] [format("rgba16f")] WTexture2D<float4> output_image;
// texels on a side of a shadow map
static const float SHADOW_MAP_SIZE = 512.0;
#else
[vk::binding(11, 0)] Texture2DArray<float> shadow_maps;
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
// aliases textures
[vk::binding(0, TEXTURES_SET)] TextureCube cube_textures[];
// the samplers, as the comparison sampler of the shadow maps needs
[vk::binding(1, TEXTURES_SET)] SamplerComparisonState compare_samplers[];
[vk::binding(2, TEXTURES_SET)] [format("rgba16f")] RWTexture2D<float4> lit_images[];
#endif

groupshared Atomic<uint> tile_min_bits;
groupshared Atomic<uint> tile_max_bits;
groupshared Atomic<uint> tile_light_count;
groupshared uint tile_lights[MAX_LIGHTS];

float scene_depth(View camera, int2 pixel)
{
#if BACKEND_WGPU
    return depth_texture.Load(int3(pixel, 0));
#else
    return textures[NonUniformResourceIndex(camera.images[IMAGE_DEPTH])].Load(int3(pixel, 0)).r;
#endif
}

float4 camera_image(View camera, uint a, int2 pixel)
{
#if BACKEND_WGPU
    switch (a) {
    case IMAGE_NORMAL: return normal_texture.Load(int3(pixel, 0));
    case IMAGE_ALBEDO: return albedo_texture.Load(int3(pixel, 0));
    case IMAGE_METALLIC_ROUGHNESS: return metallic_roughness_texture.Load(int3(pixel, 0));
    case IMAGE_EMISSIVE: return emissive_texture.Load(int3(pixel, 0));
    default: return ambient_occlusion_texture.Load(int3(pixel, 0));
    }
#else
    return textures[NonUniformResourceIndex(camera.images[a])].Load(int3(pixel, 0));
#endif
}

void store_lit(int2 pixel, float4 color)
{
#if BACKEND_WGPU
    output_image.Store(pixel, color);
#else
    lit_images[lighting_push.output_index][pixel] = color;
#endif
}

// Difference of world positions across `pixel` along `axis`, taken towards
// the neighbor nearer in depth so a silhouette doesn't bend it.
float3 surface_step(View camera, int2 pixel, int2 axis, float3 frag_pos, float depth)
{
    int2 hi = min(pixel + axis, int2(camera.extent) - 1);
    int2 lo = max(pixel - axis, int2(0));
    float hi_depth = scene_depth(camera, hi);
    float lo_depth = scene_depth(camera, lo);
    if (all(lo == pixel) || (any(hi != pixel) && abs(hi_depth - depth) <= abs(lo_depth - depth))) {
        return world_position(camera, (float2(hi) + 0.5) / camera.extent, hi_depth) - frag_pos;
    }
    return frag_pos - world_position(camera, (float2(lo) + 0.5) / camera.extent, lo_depth);
}

// Normal of the rasterized surface at `pixel`, rebuilt from the depth buffer
// and facing the camera: unlike the G-buffer normal, neither normal maps nor
// smooth shading tilt it off the surface the shadow map recorded. `fallback`
// where the surface is degenerate.
float3 geometric_normal(View camera, int2 pixel, float3 frag_pos, float depth, float3 fallback)
{
    float3 c = cross(surface_step(camera, pixel, int2(1, 0), frag_pos, depth),
                     surface_step(camera, pixel, int2(0, 1), frag_pos, depth));
    float len = length(c);
    if (len < 1e-12) return fallback;
    float3 n = c / len;
    return dot(n, camera.position.xyz - frag_pos) < 0.0 ? -n : n;
}

// Where a placed light sits and shines: its node's translation and normalized forward (-Z)
// axis, as lights.odin light_pose.
float3 light_position(LightPlacement p)
{
    return float3(nodes[p.node].world_matrix[0][3], nodes[p.node].world_matrix[1][3], nodes[p.node].world_matrix[2][3]);
}

float3 light_forward(LightPlacement p)
{
    float4x4 m = nodes[p.node].world_matrix;
    float3 forward = -float3(m[0][2], m[1][2], m[2][2]);
    return dot(forward, forward) > 1e-6 ? normalize(forward) : float3(0.0, -1.0, 0.0);
}

// Direction from the fragment towards the light.
float3 light_direction(LightPlacement p, float3 frag_pos)
{
    if (lights[p.light].light_type == LIGHT_DIRECTIONAL) return -light_forward(p);
    return normalize(light_position(p) - frag_pos);
}

// Light reaching a fragment: 1 when lit, SHADOW_FLOOR when fully occluded.
static const float SHADOW_FLOOR = 0.1;
// Shadow texels from a lookup to the farthest texel its filter reads: a 3x3
// grid of 2x2 compare taps.
static const float SHADOW_FILTER_RADIUS = 2.0;
// Cascades of a directional light's map, SHADOW_CASCADES in lights.odin.
static const uint SHADOW_CASCADES = 4;

// Texels on a side of a shadow map.
float shadow_map_size()
{
#if BACKEND_WGPU
    return SHADOW_MAP_SIZE;
#else
    uint w, h, layers;
    shadow_maps.GetDimensions(w, h, layers);
    return float(w);
#endif
}

// The cascade of the directional light with shadow views from `first` towards p: the finest
// whose box holds p, with room for the filter (NO_FACE beyond the last).
uint cascade_face(uint first, float3 p)
{
    // the normal offset moves p up to SHADOW_FILTER_RADIUS + 0.5 texels
    float edge = 1.0 - 2.0 * (2.0 * SHADOW_FILTER_RADIUS + 0.5) / shadow_map_size();
    for (uint c = 0; c < SHADOW_CASCADES; c++) {
        float4 s = mul(views[first + c].view_projection, float4(p, 1.0));
        // a cascade's box is no deeper than wide: with the light along
        // the view, far points project into the near cascades too
        if (abs(s.x) < edge && abs(s.y) < edge && s.z > 0.0 && s.z < 1.0) return c;
    }
    return NO_FACE;
}

// The shadow face seen from the light towards p: the cube face on the major
// axis of the light-to-p direction (+X, -X, +Y, -Y, +Z, -Z) for a point light,
// the only face otherwise.
uint shadow_face(LightPlacement placed, float3 p)
{
    if (lights[placed.light].light_type != LIGHT_POINT) return 0;
    float3 d = p - light_position(placed);
    float3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z) return d.x >= 0.0 ? 0 : 1;
    if (a.y >= a.z) return d.y >= 0.0 ? 2 : 3;
    return d.z >= 0.0 ? 4 : 5;
}

// World size of a shadow texel at frag_pos, growing with view depth (a point
// light's cube faces span 90 degrees, a spot light's map its cone).
float shadow_texel(LightPlacement placed, float3 frag_pos)
{
    Light light = lights[placed.light];
    float3 d = frag_pos - light_position(placed);
    if (light.light_type == LIGHT_POINT) {
        float3 a = abs(d);
        return 2.0 * tan(0.25 * PI) / shadow_map_size() * max(a.x, max(a.y, a.z));
    }
    float per_depth = 2.0 * tan(0.5 * max(light.angle_outer * 2.0, 0.001)) / shadow_map_size();
    return per_depth * max(dot(d, light_forward(placed)), 0.0);
}

// How far a shadow lookup moves off the surface along its geometric normal n,
// in texels: further the more the surface turns from the light direction l, so
// the filter's texels all lie in front of it.
float shadow_offset(float3 n, float3 l)
{
    float cos_theta = clamp(dot(n, l), 0.0, 1.0);
    return 0.5 + SHADOW_FILTER_RADIUS * sqrt(1.0 - cos_theta * cos_theta);
}

// One compare tap of face `view`, at uv of the face and the tap's offset in texels. Vulkan
// reads the face's array layer (zero gradients sample mip 0, there are no implicit
// derivatives in compute), unflipped: clip y = -1 is texel row 0. wgpu reads the face's tile of
// the atlas, taps clamped to the tile as an array layer's edge would clamp them.
float shadow_tap(View view, float2 uv, int2 tap, float reference)
{
#if BACKEND_WGPU
    uint aw, ah;
    shadow_maps.GetDimensions(aw, ah);
    float2 atlas = float2(aw, ah);
    uint columns = uint(atlas.x / SHADOW_MAP_SIZE);
    float2 origin = float2(float(view.layer % columns), float(view.layer / columns)) * SHADOW_MAP_SIZE;
    float2 lo = (origin + 0.5) / atlas;
    float2 hi = (origin + SHADOW_MAP_SIZE - 0.5) / atlas;
    float2 coord = (origin + uv * SHADOW_MAP_SIZE + float2(tap)) / atlas;
    return shadow_maps.SampleCmpLevelZero(shadow_compare, clamp(coord, lo, hi), reference);
#else
    float2 texel = float2(1.0 / shadow_map_size());
    return shadow_maps.SampleCmpLevelZero(compare_samplers[SAMPLER_SHADOW_COMPARE], float3(uv + float2(tap) * texel, float(view.layer)), reference);
#endif
}

// Depth test of p against shadow face `view`, filtered over a 3x3 grid of 2x2
// compare taps. The view projects p into its shadow map.
float shadow_lookup(View view, float3 p)
{
    float4 light_space = mul(view.view_projection, float4(p, 1.0));
    float3 coord = light_space.xyz / light_space.w;
    float2 uv = coord.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 1.0;
    }
    float reference = clamp(coord.z, 0.0, 1.0);
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            lit += shadow_tap(view, uv, int2(x, y), reference);
        }
    }
    return lerp(SHADOW_FLOOR, 1.0, lit / 9.0);
}

// Light of a placed light reaching frag_pos: 1 when lit, SHADOW_FLOOR when occluded. A
// directional light's cascade sets the texel size, so it is picked before the offset.
float calculate_shadow(LightPlacement placed, float3 frag_pos, float3 n, float3 l)
{
    // no shadow map
    if (placed.shadow_map == 0) return 1.0;
    if (lights[placed.light].light_type == LIGHT_DIRECTIONAL) {
        uint face = cascade_face(placed.shadow_map, frag_pos);
        if (face == NO_FACE) return 1.0;
        View view = views[placed.shadow_map + face];
        float3 p = frag_pos + n * (shadow_offset(n, l) * 2.0 / (view.projection[0][0] * shadow_map_size()));
        return shadow_lookup(view, p);
    }
    // the texel size doesn't depend on the face; the offset may cross one
    float3 p = frag_pos + n * (shadow_offset(n, l) * shadow_texel(placed, frag_pos));
    return shadow_lookup(views[placed.shadow_map + shadow_face(placed, p)], p);
}

// Inverse-square falloff windowed to reach zero, with zero slope, at radius.
float distance_falloff(float dist, float radius)
{
    float r = dist / max(radius, 0.01);
    float window = clamp(1.0 - r * r * r * r, 0.0, 1.0);
    return window * window / (dist * dist + 1.0);
}

float attenuation(LightPlacement placed, float3 frag_pos)
{
    Light light = lights[placed.light];
    if (light.light_type == LIGHT_DIRECTIONAL) return 1.0;
    float3 to_frag = frag_pos - light_position(placed);
    float dist = length(to_frag);
    float falloff = distance_falloff(dist, light.radius);
    if (light.light_type == LIGHT_POINT) return falloff;
    float cos_angle = dot(to_frag / max(dist, 0.0001), light_forward(placed));
    return falloff * smoothstep(cos(light.angle_outer), cos(light.angle_inner), cos_angle);
}

// The surface a pixel shows, as the lights read it.
struct Surface {
    float3 position;
    // shading normal, from the G-buffer
    float3 normal;
    // geometric_normal, for the shadow lookup
    float3 geometric;
    float3 v;
    float3 albedo;
    float metallic;
    float roughness;
}

// Cook-Torrance BRDF of light arriving along l (towards the light) as `radiance`.
float3 brdf(float3 l, float3 radiance, Surface s)
{
    float3 f0 = lerp(float3(0.04), s.albedo, s.metallic);
    float3 h = normalize(s.v + l);
    float n_dot_l = max(dot(s.normal, l), 0.0);
    float n_dot_v = max(dot(s.normal, s.v), 0.01);
    float n_dot_h = max(dot(s.normal, h), 0.0);
    float alpha = s.roughness * s.roughness;
    float alpha2 = alpha * alpha;
    float denom = max(n_dot_h * n_dot_h * (alpha2 - 1.0) + 1.0, 0.001);
    float ndf = alpha2 / (PI * denom * denom);
    float k = pow(s.roughness + 1.0, 2.0) / 8.0;
    float g = n_dot_l / (n_dot_l * (1.0 - k) + k);
    g *= n_dot_v / (n_dot_v * (1.0 - k) + k);
    float3 f = f0 + (1.0 - f0) * pow(1.0 - max(dot(h, s.v), 0.0), 5.0);
    float3 spec = ndf * g * f / (4.0 * n_dot_v * n_dot_l + 0.01);
    float3 ks = clamp(f, 0.0, 1.0);
    float3 kd = (float3(1.0) - ks) * (1.0 - s.metallic);
    return (kd * s.albedo / PI + spec) * radiance * n_dot_l;
}

// One placed light, shadowed.
float3 direct_light(LightPlacement placed, Surface s)
{
    Light light = lights[placed.light];
    float3 l = light_direction(placed, s.position);
    // facing away or out of reach, the BRDF is zero: skip the shadow lookup
    if (dot(s.normal, l) <= 0.0) return float3(0.0);
    float atten = attenuation(placed, s.position);
    if (atten <= 0.0) return float3(0.0);
    return brdf(l, light.color * light.intensity * atten, s) * calculate_shadow(placed, s.position, s.geometric, l);
}

float prefilter_max_lod()
{
    uint w, h, levels;
#if BACKEND_WGPU
    prefilter_cube.GetDimensions(0, w, h, levels);
#else
    cube_textures[NonUniformResourceIndex(lighting_push.prefilter_index)].GetDimensions(0, w, h, levels);
#endif
    return float(levels - 1);
}

float3 sample_environment(float2 uv)
{
#if BACKEND_WGPU
    return environment_map.SampleLevel(linear_repeat, uv, 0.0).rgb;
#else
    return textures[NonUniformResourceIndex(lighting_push.environment_index)].SampleLevel(sampler_of(SAMPLER_LINEAR_REPEAT), uv, 0.0).rgb;
#endif
}

float3 sample_prefilter(float3 dir, float lod)
{
#if BACKEND_WGPU
    return prefilter_cube.SampleLevel(linear_clamp, dir, lod).rgb;
#else
    return cube_textures[NonUniformResourceIndex(lighting_push.prefilter_index)].SampleLevel(sampler_of(SAMPLER_LINEAR_CLAMP), dir, lod).rgb;
#endif
}

float3 sample_irradiance(float3 dir)
{
#if BACKEND_WGPU
    return irradiance_cube.SampleLevel(linear_clamp, dir, 0.0).rgb;
#else
    return cube_textures[NonUniformResourceIndex(lighting_push.irradiance_index)].SampleLevel(sampler_of(SAMPLER_LINEAR_CLAMP), dir, 0.0).rgb;
#endif
}

float2 sample_brdf_lut(float2 uv)
{
#if BACKEND_WGPU
    return brdf_lut.SampleLevel(linear_clamp, uv, 0.0).rg;
#else
    return textures[NonUniformResourceIndex(lighting_push.brdf_lut_index)].SampleLevel(sampler_of(SAMPLER_LINEAR_CLAMP), uv, 0.0).rg;
#endif
}

float3 sample_skybox(View camera, float2 uv)
{
    float2 ndc = uv * 2.0 - 1.0;
    float4 world_far = mul(camera.inv_view_projection, float4(ndc, 1.0, 1.0));
    float3 dir = normalize(world_far.xyz / world_far.w - camera.position.xyz);
    float b = clamp(lighting_push.skybox_blur, 0.0, 1.0);
    if (b <= 0.0 || lighting_push.prefilter_index == NO_TEXTURE) {
        return sample_environment(dir_to_equirect_uv(dir));
    }
    return sample_prefilter(dir, b * prefilter_max_lod());
}

// The ambient occlusion at a pixel showing s: the average over the 4x4 texels its pattern
// repeats in (shader/ambient_occlusion.slang), of those on s's plane. 1 without the image.
float ambient_visibility(View camera, int2 pixel, Surface s)
{
    if (lighting_push.ambient_occlusion == 0) return 1.0;
    float tolerance = 0.02 * length(camera.position.xyz - s.position) + 1e-3;
    float sum = 0.0;
    float weight = 0.0;
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            int2 q = clamp(pixel + int2(x, y), int2(0), int2(camera.extent) - 1);
            float q_depth = scene_depth(camera, q);
            if (q_depth >= 1.0) continue;
            float3 q_pos = world_position(camera, (float2(q) + 0.5) / camera.extent, q_depth);
            float w = clamp(1.0 - abs(dot(q_pos - s.position, s.geometric)) / tolerance, 0.0, 1.0);
            sum += w * camera_image(camera, IMAGE_AMBIENT_OCCLUSION, q).r;
            weight += w;
        }
    }
    return weight > 0.0 ? sum / weight : 1.0;
}

// Light bouncing between occluded surfaces: brighter albedo gives back part of what ambient
// occlusion takes (Jimenez et al. 2016).
float3 multi_bounce(float visibility, float3 albedo)
{
    float3 a = 2.0404 * albedo - 0.3324;
    float3 b = -4.7951 * albedo + 0.6417;
    float3 c = 2.7552 * albedo + 0.6903;
    return max(float3(visibility), ((visibility * a + b) * visibility + c) * visibility);
}

// The share of a reflection's lobe ambient occlusion leaves open (Lagarde and de Rousiers 2014).
float specular_occlusion(float n_dot_v, float visibility, float roughness)
{
    return clamp(pow(n_dot_v + visibility, exp2(-16.0 * roughness - 1.0)) - 1.0 + visibility, 0.0, 1.0);
}

// Image-based lighting at intensity ibl_intensity, from the unnormalized G-buffer normal,
// occluded by visibility.
float3 ambient_light(float ibl_intensity, float3 normal, Surface s, float roughness, float visibility)
{
    if (ibl_intensity <= 0.0 || lighting_push.prefilter_index == NO_TEXTURE) return float3(0.0);
    float3 r = reflect(-s.v, normal);
    float n_dot_v = max(dot(normal, s.v), 0.0);
    float3 f0 = lerp(float3(0.04), s.albedo, s.metallic);
    float3 f = fresnel_schlick_roughness(n_dot_v, f0, roughness);
    float3 irradiance = sample_irradiance(normal);
    float3 kd = (float3(1.0) - f) * (1.0 - s.metallic);
    float3 prefiltered = sample_prefilter(r, roughness * prefilter_max_lod());
    float2 lut = sample_brdf_lut(float2(n_dot_v, roughness));
    float3 specular = prefiltered * (f * lut.x + lut.y);
    float3 diffuse = kd * irradiance * s.albedo * multi_bounce(visibility, s.albedo);
    specular *= specular_occlusion(n_dot_v, visibility, roughness);
    return (diffuse + specular) * ibl_intensity;
}

// Whether the sphere (center, radius) meets the box [lo, hi].
bool sphere_meets_box(float3 center, float radius, float3 lo, float3 hi)
{
    float3 d = clamp(center, lo, hi) - center;
    return dot(d, d) <= radius * radius;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint3 gid : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex)
{
    View camera = views[lighting_push.camera_index];
    int2 extent = int2(camera.extent);
    int2 pixel = int2(gid.xy);
    bool inside = pixel.x < extent.x && pixel.y < extent.y;

    // the tile's depth range, over the pixels that show a surface
    if (local == 0) {
        tile_min_bits.store(asuint(1.0));
        tile_max_bits.store(0);
        tile_light_count.store(0);
    }
    GroupMemoryBarrierWithGroupSync();
    float depth = inside ? scene_depth(camera, pixel) : 1.0;
    // depth is positive: its bits order as it does
    if (depth < 1.0) {
        tile_min_bits.min(asuint(depth));
        tile_max_bits.max(asuint(depth));
    }
    GroupMemoryBarrierWithGroupSync();

    // the visible directional lights, and the placed lights whose sphere meets the tile's box
    float depth_min = asfloat(tile_min_bits.load());
    float depth_max = asfloat(tile_max_bits.load());
    if (depth_min <= depth_max) {
        float2 tile_lo = float2(group.xy * TILE) / camera.extent;
        float2 tile_hi = float2(min(int2((group.xy + 1) * TILE), extent)) / camera.extent;
        float3 lo = float3(1e30);
        float3 hi = float3(-1e30);
        for (uint c = 0; c < 8; c++) {
            float2 uv = float2((c & 1) != 0 ? tile_hi.x : tile_lo.x, (c & 2) != 0 ? tile_hi.y : tile_lo.y);
            float3 p = world_position(camera, uv, (c & 4) != 0 ? depth_max : depth_min);
            lo = min(lo, p);
            hi = max(hi, p);
        }
        for (uint i = local; i < lighting_push.light_count; i += TILE * TILE) {
            LightPlacement p = placements[i];
            if (p.light == 0 || (nodes[p.node].flags & NODE_FLAG_VISIBLE) == 0) continue;
            Light light = lights[p.light];
            if (light.light_type == LIGHT_DIRECTIONAL || sphere_meets_box(light_position(p), light.radius, lo, hi)) {
                tile_lights[tile_light_count.add(1)] = i;
            }
        }
    }
    GroupMemoryBarrierWithGroupSync();
    if (!inside) return;

    float2 uv = (float2(pixel) + 0.5) / camera.extent;
    // background (depth left at the far clear value): the skybox, if any
    if (depth >= 1.0) {
        float3 sky = float3(0.0);
        if (lighting_push.skybox_intensity > 0.0 && lighting_push.environment_index != NO_TEXTURE) sky = sample_skybox(camera, uv) * lighting_push.skybox_intensity;
        store_lit(pixel, float4(sky, 1.0));
        return;
    }
    float3 raw_normal = camera_image(camera, IMAGE_NORMAL, pixel).xyz * 2.0 - 1.0;
    float2 mr = camera_image(camera, IMAGE_METALLIC_ROUGHNESS, pixel).rg;
    Surface s;
    s.position = world_position(camera, uv, depth);
    // unfiltered: a blend across a silhouette is no surface's normal
    s.normal = normalize(raw_normal);
    s.v = normalize(camera.position.xyz - s.position);
    s.albedo = camera_image(camera, IMAGE_ALBEDO, pixel).rgb;
    s.metallic = clamp(mr.r, 0.0, 1.0);
    s.geometric = geometric_normal(camera, pixel, s.position, depth, s.normal);

    float3 color = camera_image(camera, IMAGE_EMISSIVE, pixel).rgb;
    color += ambient_light(lighting_push.ibl_intensity, raw_normal, s, mr.g, ambient_visibility(camera, pixel, s));
    s.roughness = clamp(mr.g, 0.08, 1.0);
    uint listed = tile_light_count.load();
    for (uint i = 0; i < listed; i++) {
        color += direct_light(placements[tile_lights[i]], s);
    }
    store_lit(pixel, float4(color, 1.0));
}
