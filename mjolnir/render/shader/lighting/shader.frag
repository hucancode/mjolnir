#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;
const uint SAMPLER_SHADOW_COMPARE = 4u;
layout(constant_id = 0) const uint LIGHT_TYPE = 0u;

const uint LIGHT_POINT = 0u;
const uint LIGHT_SPOT = 1u;
const uint LIGHT_DIRECTIONAL = 2u;
const uint NO_SHADOW = 0xFFFFFFFFu;

layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 11) uniform texture2DArray shadow_maps;
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

struct Light {
    vec4 color;
    vec3 position;
    float radius;
    vec3 direction;
    float angle_inner;
    float angle_outer;
    uint shadow_map; // view index of the first shadow face
    float shadow_texel; // world size of a shadow texel; per unit of view depth for point and spot
    uint _pad0;
};

// View.attachments indices (AttachmentType)
const uint ATTACHMENT_NORMAL = 1u;
const uint ATTACHMENT_ALBEDO = 2u;
const uint ATTACHMENT_METALLIC_ROUGHNESS = 3u;
const uint ATTACHMENT_EMISSIVE = 4u;
const uint ATTACHMENT_DEPTH = 5u;

struct View {
    mat4 view;
    mat4 projection;
    mat4 view_projection;
    mat4 inv_view_projection; // rebuilds world positions from depth
    vec4 planes[6]; // normalized, pointing inward
    vec4 position;
    vec2 extent;
    float near;
    float far;
    uint attachments[6]; // this frame's bindless images, by AttachmentType
    uint pyramid; // bindless depth pyramid
    uint occlusion_mask; // bit t: material type t is tested against the pyramid
    uint list_stride;
    uint type_mask; // bit t: material type t is drawn
    uint require_flags; // node flags a drawn node has
    uint instance_tag; // OR-ed into first_instance above the node index
    uint layer;
    uint draw_list; // bindless draw lists the view appends to
    uint list_capacity; // draws per list
    uint _pad0;
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

layout(set = 0, binding = 10) readonly buffer LightBuffer {
    Light lights[];
};

layout(push_constant) uniform PushConstant {
    uint camera_index;
    uint irradiance_index;
    uint prefilter_index;
    uint brdf_lut_index;
    uint environment_index;
    float skybox_intensity;
    float skybox_blur;
};

layout(location = 0) flat in uint v_light;

// World position of the G-buffer texel at framebuffer uv, rebuilt from its
// depth. Clip-space y points down, so ndc follows uv on both axes.
vec3 worldPosition(View camera, vec2 uv, float depth) {
    vec4 p = camera.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return p.xyz / p.w;
}

float sceneDepth(View camera, ivec2 pixel) {
    return texelFetch(sampler2D(textures[camera.attachments[ATTACHMENT_DEPTH]], samplers[SAMPLER_NEAREST_CLAMP]), pixel, 0).r;
}

// Difference of world positions across `pixel` along `axis`, taken towards
// the neighbor nearer in depth so a silhouette doesn't bend it.
vec3 surfaceStep(View camera, ivec2 pixel, ivec2 axis, vec3 fragPos, float depth) {
    ivec2 hi = min(pixel + axis, ivec2(camera.extent) - 1);
    ivec2 lo = max(pixel - axis, ivec2(0));
    float hiDepth = sceneDepth(camera, hi);
    float loDepth = sceneDepth(camera, lo);
    if (lo == pixel || (hi != pixel && abs(hiDepth - depth) <= abs(loDepth - depth))) {
        return worldPosition(camera, (vec2(hi) + 0.5) / camera.extent, hiDepth) - fragPos;
    }
    return fragPos - worldPosition(camera, (vec2(lo) + 0.5) / camera.extent, loDepth);
}

// Normal of the rasterized surface at `pixel`, rebuilt from the depth buffer
// and facing the camera: unlike the G-buffer normal, neither normal maps nor
// smooth shading tilt it off the surface the shadow map recorded. `fallback`
// where the surface is degenerate.
vec3 geometricNormal(View camera, ivec2 pixel, vec3 fragPos, float depth, vec3 fallback) {
    vec3 c = cross(surfaceStep(camera, pixel, ivec2(1, 0), fragPos, depth),
                   surfaceStep(camera, pixel, ivec2(0, 1), fragPos, depth));
    float len = length(c);
    if (len < 1e-12) return fallback;
    vec3 n = c / len;
    return dot(n, camera.position.xyz - fragPos) < 0.0 ? -n : n;
}

// The light this fragment shades, read once in main.
Light light;

// Direction from the fragment towards the light.
vec3 lightDirection(vec3 fragPos) {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) return -light.direction;
    return normalize(light.position - fragPos);
}

// Light reaching a fragment: 1 when lit, SHADOW_FLOOR when fully occluded.
const float SHADOW_FLOOR = 0.1;
// Shadow texels from a lookup to the farthest texel its filter reads: a 3x3
// grid of 2x2 compare taps.
const float SHADOW_FILTER_RADIUS = 2.0;
// Cascades of a directional light's map, SHADOW_CASCADES in scene.odin.
const uint SHADOW_CASCADES = 4u;

// Texels on a side of a shadow map.
float shadowMapSize() {
    return float(textureSize(sampler2DArrayShadow(shadow_maps, samplers[SAMPLER_SHADOW_COMPARE]), 0).x);
}

// The shadow face seen from the light towards p: the cube face on the major
// axis of the light-to-p direction (+X, -X, +Y, -Y, +Z, -Z) for a point light,
// the finest cascade whose box holds p, with room for the filter, for a directional
// light (NO_SHADOW beyond the last), the only face otherwise.
uint shadowFace(vec3 p) {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        // the normal offset moves p up to SHADOW_FILTER_RADIUS + 0.5 texels
        float edge = 1.0 - 2.0 * (2.0 * SHADOW_FILTER_RADIUS + 0.5) / shadowMapSize();
        for (uint c = 0u; c < SHADOW_CASCADES; c++) {
            vec4 s = views[light.shadow_map + c].view_projection * vec4(p, 1.0);
            // a cascade's box is no deeper than wide: with the light along
            // the view, far points project into the near cascades too
            if (abs(s.x) < edge && abs(s.y) < edge && s.z > 0.0 && s.z < 1.0) return c;
        }
        return NO_SHADOW;
    }
    if (LIGHT_TYPE != LIGHT_POINT) return 0u;
    vec3 d = p - light.position;
    vec3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z) return d.x >= 0.0 ? 0u : 1u;
    if (a.y >= a.z) return d.y >= 0.0 ? 2u : 3u;
    return d.z >= 0.0 ? 4u : 5u;
}

// World size of a shadow texel of `view` at fragPos: constant for an
// orthographic map, read from its projection, growing with view depth for a
// perspective one.
float shadowTexel(vec3 fragPos, View view) {
    vec3 d = fragPos - light.position;
    if (LIGHT_TYPE == LIGHT_POINT) {
        vec3 a = abs(d);
        return light.shadow_texel * max(a.x, max(a.y, a.z));
    }
    if (LIGHT_TYPE == LIGHT_SPOT) return light.shadow_texel * max(dot(d, light.direction), 0.0);
    return 2.0 / (view.projection[0][0] * shadowMapSize());
}

// Depth test of fragPos against its shadow face, filtered over a 3x3 grid of
// 2x2 compare taps. The lookup moves off the surface along its geometric
// normal n, further the more the surface turns from the light direction L,
// so the filter's texels all lie in front of it. The face's view projects it
// into its atlas layer, rendered with an unflipped viewport (clip y = -1 is
// texel row 0).
float calculateShadow(vec3 fragPos, vec3 n, vec3 L) {
    if (light.shadow_map == NO_SHADOW) return 1.0;
    float cosTheta = clamp(dot(n, L), 0.0, 1.0);
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    float offset = 0.5 + SHADOW_FILTER_RADIUS * sinTheta;
    vec3 p = fragPos;
    uint face;
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        // the cascade sets the texel size, so pick it before the offset
        face = shadowFace(p);
        if (face == NO_SHADOW) return 1.0;
        p += n * (offset * shadowTexel(p, views[light.shadow_map + face]));
    } else {
        // the texel size doesn't depend on the face; the offset may cross one
        p += n * (offset * shadowTexel(p, views[light.shadow_map]));
        face = shadowFace(p);
    }
    View view = views[light.shadow_map + face];
    vec4 lightSpacePos = view.view_projection * vec4(p, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
    if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
        shadowCoord.y < 0.0 || shadowCoord.y > 1.0) {
        return 1.0;
    }
    shadowCoord.z = clamp(shadowCoord.z, 0.0, 1.0);
    vec2 texel = vec2(1.0 / shadowMapSize());
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 uv = shadowCoord.xy + vec2(x, y) * texel;
            lit += texture(sampler2DArrayShadow(shadow_maps, samplers[SAMPLER_SHADOW_COMPARE]), vec4(uv, float(view.layer), shadowCoord.z));
        }
    }
    return mix(SHADOW_FLOOR, 1.0, lit / 9.0);
}

float attenuation(vec3 fragPos) {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) return 1.0;
    if (LIGHT_TYPE == LIGHT_POINT) {
        float norm_dist = length(light.position - fragPos) / max(0.01, light.radius);
        return light.radius * (1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0));
    }
    vec3 tipToFrag = fragPos - light.position;
    vec3 cone_axis = light.direction;
    float distance_along_axis = dot(tipToFrag, cone_axis);
    float radial_distance = length(tipToFrag - distance_along_axis * cone_axis);
    float cone_radius_at_height = distance_along_axis * tan(light.angle_outer);
    float normalized_radial = radial_distance / max(cone_radius_at_height, 0.001);
    float inner_outer_ratio = tan(light.angle_inner) / tan(light.angle_outer);
    float spotEffect = smoothstep(1.0, inner_outer_ratio, normalized_radial);
    float norm_dist = distance_along_axis / max(0.01, light.radius);
    spotEffect *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    return light.radius * spotEffect;
}

// Cook-Torrance BRDF
vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 light_col = light.color.rgb * light.color.a;
    vec3 L = lightDirection(fragPos);
    vec3 H = normalize(V + L);
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.01);
    float NdotH = max(dot(N, H), 0.0);
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denom = max(NdotH * NdotH * (alpha2 - 1.0) + 1.0, 0.001);
    float NDF = alpha2 / (PI * denom * denom);
    float k = pow(roughness + 1.0, 2.0) / 8.0;
    float G = NdotL / (NdotL * (1.0 - k) + k);
    G *= NdotV / (NdotV * (1.0 - k) + k);
    vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);
    vec3 spec = NDF * G * F / (4.0 * NdotV * NdotL + 0.01);
    vec3 kS = clamp(F, 0.0, 1.0);
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);
    return (kD * albedo / PI + spec) * light_col * NdotL * attenuation(fragPos);
}

void main() {
    light = lights[v_light];
    View camera = views[camera_index];
    vec2 uv = gl_FragCoord.xy / camera.extent;

    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = sceneDepth(camera, pixel);
    vec3 fragPos = worldPosition(camera, uv, depth);
    // unfiltered: a blend across a silhouette is no surface's normal
    vec3 normal = normalize(texelFetch(sampler2D(textures[camera.attachments[ATTACHMENT_NORMAL]], samplers[SAMPLER_NEAREST_CLAMP]), pixel, 0).xyz * 2.0 - 1.0);
    vec3 albedo = texture(sampler2D(textures[camera.attachments[ATTACHMENT_ALBEDO]], samplers[SAMPLER_LINEAR_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[camera.attachments[ATTACHMENT_METALLIC_ROUGHNESS]], samplers[SAMPLER_LINEAR_CLAMP]), uv).rg;

    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.08, 1.0);

    vec3 L = lightDirection(fragPos);
    // facing away, the BRDF is zero: skip the shadow lookup
    if (dot(normal, L) <= 0.0) {
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    vec3 V = normalize(camera.position.xyz - fragPos);
    vec3 surfaceNormal = geometricNormal(camera, pixel, fragPos, depth, normal);
    float shadowFactor = calculateShadow(fragPos, surfaceNormal, L);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, fragPos);

    outColor = vec4(direct * shadowFactor, 1.0);
}
