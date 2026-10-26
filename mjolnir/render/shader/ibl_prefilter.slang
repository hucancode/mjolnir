// Specular prefilter of one mip: GGX importance samples of the environment at roughness `value`,
// weighted by n·l, each read at the mip matching the solid angle it stands for.
#include "ibl_common.slang"

float radical_inverse_vdc(uint b)
{
    uint bits = (b << 16u) | (b >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

float2 hammersley(uint i, uint n)
{
    return float2(float(i) / float(n), radical_inverse_vdc(i));
}

// The GGX normal distribution at half vector cosine n_dot_h.
float distribution_ggx(float n_dot_h, float a)
{
    float a2 = a * a;
    float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

float3 importance_sample_ggx(float2 xi, float3 n, float a)
{
    float phi = 2.0 * PI * xi.x;
    float cos_theta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
    float sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    float3 h = float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
    float3 up = abs(n.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0);
    float3 tx = normalize(cross(up, n));
    float3 ty = cross(n, tx);
    return normalize(tx * h.x + ty * h.y + n * h.z);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    float3 n;
    if (!texel_dir(gid, n)) return;
    float3 v = n;
    float a = max(precompute_push.value * precompute_push.value, 1e-4);
    float3 color = float3(0.0);
    float weight = 0.0;
    for (uint i = 0; i < precompute_push.sample_count; i++) {
        float3 h = importance_sample_ggx(hammersley(i, precompute_push.sample_count), n, a);
        float3 l = normalize(2.0 * dot(v, h) * h - v);
        float n_dot_l = max(dot(n, l), 0.0);
        if (n_dot_l <= 0.0) continue;
        // pdf of l with v = n: D * n_dot_h / (4 * v_dot_h) = D / 4
        float pdf = distribution_ggx(max(dot(n, h), 0.0), a) * 0.25;
        float solid_angle = 1.0 / (float(precompute_push.sample_count) * pdf + 1e-4);
        color += sample_source(l, source_lod(l, solid_angle) + 1.0) * n_dot_l;
        weight += n_dot_l;
    }
    color /= max(weight, 1e-4);
    store_destination(gid, float4(color, 1.0));
}
