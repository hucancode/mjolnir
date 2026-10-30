// Ground-truth ambient occlusion (Jimenez et al. 2016, after XeGTAO), from the camera's depth
// and G-buffer normals: an invocation per pixel walks SLICES screen-space directions, finds on
// each the highest horizon on either side within `radius` world units, and integrates the
// cosine-weighted visible arc of its normal between them. The slices and step offsets are
// rotated by a 4x4 pattern the lighting pass averages away. Writes visibility^intensity,
// 1 for the background.
#include "common.slang"

static const uint SLICES = 2;
static const uint STEPS = 4;
// the part of radius over which an occluder's weight falls to zero
static const float FALLOFF_RANGE = 0.615;

struct AmbientOcclusionPush {
    uint camera_index;
    // storage image the occlusion is written to (a group on wgpu)
    uint output_index;
    float radius;
    float intensity;
}
PUSH_BLOCK(AmbientOcclusionPush, ao_push)

// View.images indices (CameraImage)
static const uint IMAGE_NORMAL = 1;
static const uint IMAGE_DEPTH = 5;

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D normal_texture;
[vk::binding(1, 1)] DepthTexture2D depth_texture;
[vk::binding(0, 3)] [format("rgba8")] WTexture2D<float4> output_image;
#else
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
[vk::binding(2, TEXTURES_SET)] [format("rgba8")] RWTexture2D<float4> ao_images[];
#endif

float scene_depth(View camera, int2 pixel)
{
#if BACKEND_WGPU
    return depth_texture.Load(int3(pixel, 0));
#else
    return textures[NonUniformResourceIndex(camera.images[IMAGE_DEPTH])].Load(int3(pixel, 0)).r;
#endif
}

float3 scene_normal(View camera, int2 pixel)
{
#if BACKEND_WGPU
    float3 n = normal_texture.Load(int3(pixel, 0)).xyz;
#else
    float3 n = textures[NonUniformResourceIndex(camera.images[IMAGE_NORMAL])].Load(int3(pixel, 0)).xyz;
#endif
    return normalize(n * 2.0 - 1.0);
}

void store_occlusion(int2 pixel, float visibility)
{
    float4 v = float4(visibility, visibility, visibility, 1.0);
#if BACKEND_WGPU
    output_image.Store(pixel, v);
#else
    ao_images[ao_push.output_index][pixel] = v;
#endif
}

static const uint BAYER4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

// 4x4 ordered dither, in [0, 1)
float bayer4(int2 pixel)
{
    return float(BAYER4[(pixel.y & 3) * 4 + (pixel.x & 3)]) / 16.0;
}

bool orthographic(View camera)
{
    return camera.projection[3][3] == 1.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    View camera = views[ao_push.camera_index];
    int2 extent = int2(camera.extent);
    int2 pixel = int2(gid.xy);
    if (pixel.x >= extent.x || pixel.y >= extent.y) return;
    float depth = scene_depth(camera, pixel);
    if (depth >= 1.0) {
        store_occlusion(pixel, 1.0);
        return;
    }
    float2 uv = (float2(pixel) + 0.5) / camera.extent;
    float3 p = world_position(camera, uv, depth);
    float3 n = scene_normal(camera, pixel);
    // towards the eye; row 2 of the view matrix is the camera's back axis
    float3 back = normalize(camera.view[2].xyz);
    float3 v = orthographic(camera) ? back : normalize(camera.position.xyz - p);

    // the radius in pixels at p's depth
    float pixels_per_unit = abs(camera.projection[1][1]) * 0.5 * camera.extent.y;
    if (!orthographic(camera)) pixels_per_unit /= max(dot(camera.position.xyz - p, back), 1e-4);
    float screen_radius = ao_push.radius * pixels_per_unit;
    if (screen_radius < 1.0) {
        store_occlusion(pixel, 1.0);
        return;
    }

    float noise_slice = bayer4(pixel);
    float noise_step = bayer4(pixel.yx + 2);
    float falloff_range = FALLOFF_RANGE * ao_push.radius;
    float visibility = 0.0;
    for (uint slice = 0; slice < SLICES; slice++) {
        float phi = (float(slice) + noise_slice) * PI / float(SLICES);
        float2 omega = float2(cos(phi), sin(phi));
        // the slice plane holds v and the world direction of omega on screen
        float3 t = world_position(camera, uv + omega / camera.extent, depth) - p;
        float3 direction = t - v * dot(t, v);
        if (dot(direction, direction) < 1e-12) continue;
        direction = normalize(direction);
        float3 axis = normalize(cross(direction, v));
        float3 projected = n - axis * dot(n, axis);
        float projected_length = length(projected);
        if (projected_length < 1e-4) continue;
        float cos_n = clamp(dot(projected, v) / projected_length, -1.0, 1.0);
        float angle_n = (dot(projected, direction) < 0.0 ? -1.0 : 1.0) * acos(cos_n);

        // horizon cosines towards +omega and -omega, starting at the tangent plane
        float low_pos = cos(angle_n + 0.5 * PI);
        float low_neg = cos(angle_n - 0.5 * PI);
        float horizon_pos = low_pos;
        float horizon_neg = low_neg;
        for (uint s = 0; s < STEPS; s++) {
            float f = (float(s) + noise_step) / float(STEPS);
            float2 offset = omega * max(f * f * screen_radius, 1.0);
            [unroll]
            for (int side = 0; side < 2; side++) {
                int2 q = int2(floor(float2(pixel) + 0.5 + (side == 0 ? offset : -offset)));
                if (any(q < 0) || any(q >= extent)) continue;
                float q_depth = scene_depth(camera, q);
                if (q_depth >= 1.0) continue;
                float3 d = world_position(camera, (float2(q) + 0.5) / camera.extent, q_depth) - p;
                float dist = length(d);
                if (dist < 1e-5) continue;
                float weight = clamp((ao_push.radius - dist) / falloff_range, 0.0, 1.0);
                float c = dot(d / dist, v);
                if (side == 0) horizon_pos = max(horizon_pos, lerp(low_pos, c, weight));
                else horizon_neg = max(horizon_neg, lerp(low_neg, c, weight));
            }
        }
        // the horizon angles about v, clamped to the normal's hemisphere
        float h_pos = angle_n + min(acos(horizon_pos) - angle_n, 0.5 * PI);
        float h_neg = angle_n + max(-acos(horizon_neg) - angle_n, -0.5 * PI);
        float sin_n = sin(angle_n);
        float arc_pos = (cos_n + 2.0 * h_pos * sin_n - cos(2.0 * h_pos - angle_n)) * 0.25;
        float arc_neg = (cos_n + 2.0 * h_neg * sin_n - cos(2.0 * h_neg - angle_n)) * 0.25;
        visibility += projected_length * (arc_pos + arc_neg);
    }
    visibility = clamp(visibility / float(SLICES), 0.0, 1.0);
    store_occlusion(pixel, pow(visibility, ao_push.intensity));
}
