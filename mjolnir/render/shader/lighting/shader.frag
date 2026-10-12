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

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    mat4 inv_view_projection;
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;
layout(set = 0, binding = 12) uniform texture2DArray shadow_maps;
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
    float shadow_bias; // per unit of tan(angle of incidence)
    uint _pad0;
};

struct View {
    vec4 planes[6];
    mat4 view_projection;
    uint camera_index;
    uint pyramid;
    uint occlusion_mask;
    uint list_stride;
    uint type_mask;
    uint require_flags;
    uint instance_tag;
    uint layer;
    uint draw_list;
    uint list_capacity;
    uint _pad0;
    uint _pad1;
};

layout(set = 0, binding = 11) readonly buffer ViewBuffer {
    View views[];
};

layout(set = 0, binding = 10) readonly buffer LightBuffer {
    Light lights[];
};

layout(push_constant) uniform PushConstant {
    uint camera_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
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
vec3 worldPosition(Camera camera, vec2 uv, float depth) {
    vec4 p = camera.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return p.xyz / p.w;
}

// The light this fragment shades, read once in main.
Light light;

// Direction from the fragment towards the light.
vec3 lightDirection(vec3 fragPos) {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) return -light.direction;
    return normalize(light.position - fragPos);
}

// tan(acos(c)) for c in [0, 1].
float tanFromCos(float c) {
    return sqrt(max(1.0 - c * c, 0.0)) / max(c, 1e-4);
}

// Light reaching a fragment: 1 when lit, SHADOW_FLOOR when fully occluded.
const float SHADOW_FLOOR = 0.1;

// The shadow face seen from the light towards fragPos: the cube face on the
// major axis of the light-to-fragment direction (+X, -X, +Y, -Y, +Z, -Z) for a
// point light, the only face otherwise.
uint shadowFace(vec3 fragPos) {
    if (LIGHT_TYPE != LIGHT_POINT) return 0u;
    vec3 d = fragPos - light.position;
    vec3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z) return d.x >= 0.0 ? 0u : 1u;
    if (a.y >= a.z) return d.y >= 0.0 ? 2u : 3u;
    return d.z >= 0.0 ? 4u : 5u;
}

// Depth test of fragPos against its shadow face: the face's view projects it
// into its atlas layer, rendered with an unflipped viewport (clip y = -1 is
// texel row 0).
float calculateShadow(vec3 fragPos, vec3 n) {
    if (light.shadow_map == NO_SHADOW) return 1.0;
    View view = views[light.shadow_map + shadowFace(fragPos)];
    vec4 lightSpacePos = view.view_projection * vec4(fragPos, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
    if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
        shadowCoord.y < 0.0 || shadowCoord.y > 1.0) {
        return 1.0;
    }
    shadowCoord.z = clamp(shadowCoord.z, 0.0, 1.0);
    float cosTheta = clamp(dot(n, lightDirection(fragPos)), 0.0, 1.0);
    float bias = clamp(light.shadow_bias * tanFromCos(cosTheta), 0.001, 0.01);
    // the compare sampler filters the depth test over 2x2 texels
    float lit = texture(sampler2DArrayShadow(shadow_maps, samplers[SAMPLER_SHADOW_COMPARE]), vec4(shadowCoord.xy, float(view.layer), shadowCoord.z - bias));
    return mix(SHADOW_FLOOR, 1.0, lit);
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
    Camera camera = camera_buffer.cameras[camera_index];
    vec2 uv = gl_FragCoord.xy / camera.viewport_extent;

    float depth = texelFetch(sampler2D(textures[depth_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), ivec2(gl_FragCoord.xy), 0).r;
    vec3 fragPos = worldPosition(camera, uv, depth);
    vec3 normal = normalize(texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).xyz * 2.0 - 1.0);
    vec3 albedo = texture(sampler2D(textures[albedo_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[metallic_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).rg;

    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.08, 1.0);

    vec3 V = normalize(camera.position.xyz - fragPos);
    float shadowFactor = calculateShadow(fragPos, normal);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, fragPos);

    outColor = vec4(direct * shadowFactor, 1.0);
}
