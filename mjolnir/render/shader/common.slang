// Declarations every shader starts with, included with `#include "common.slang"` (slangc -I this
// directory). The build defines BACKEND_VULKAN or BACKEND_WGPU (as 1, the other as 0): where the
// backends must differ a shader branches on them, and nothing else does.
//
// Vulkan binds the scene at set 0 and the bindless textures and samplers at TEXTURES_SET
// (default 1); wgpu binds per-pass groups: 0 scene buffers, 1 textures, 2 the push block
// (binding 0) and the samplers, 3 the pass's own.
#pragma once

#ifndef TEXTURES_SET
#define TEXTURES_SET 1
#endif

static const float PI = 3.14159265359;

// texture handle of a material slot without a texture
static const uint NO_TEXTURE = 0;

// MaterialType
static const uint MATERIAL_PBR = 0;
static const uint MATERIAL_TRANSPARENT = 1;
static const uint MATERIAL_WIREFRAME = 2;
static const uint MATERIAL_RANDOM_COLOR = 3;
static const uint MATERIAL_SPRITE = 4;
static const uint MATERIAL_CUSTOM = 5;

// LightType
static const uint LIGHT_POINT = 0;
static const uint LIGHT_SPOT = 1;

// node flags
static const uint NODE_FLAG_VISIBLE = 1;
static const uint NODE_FLAG_CASTS_SHADOW = 2;
// the node holds a bone range; only set on a skinned mesh
static const uint NODE_FLAG_SKINNED = 4;

static const uint SAMPLER_NEAREST_CLAMP = 0;
static const uint SAMPLER_LINEAR_CLAMP = 1;
static const uint SAMPLER_NEAREST_REPEAT = 2;
static const uint SAMPLER_LINEAR_REPEAT = 3;
static const uint SAMPLER_SHADOW_COMPARE = 4;

struct View {
    float4x4 view;
    float4x4 projection;
    float4x4 view_projection;
    // rebuilds world positions from depth
    float4x4 inv_view_projection;
    // normalized, pointing inward
    float4 planes[6];
    // world position of the camera
    float4 position;
    float2 extent;
    float near;
    float far;
    // render's texture handles, by CameraImage (bound through a group on wgpu)
    uint images[6];
    uint pyramid;
    // bit t: material type t is tested against the pyramid
    uint occlusion_mask;
    uint list_stride;
    // bit t: material type t is drawn
    uint type_mask;
    // node flags a drawn node has
    uint require_flags;
    uint instance_tag;
    uint layer;
    uint draw_list;
    uint list_capacity;
    // render's clock in seconds
    float time;
    // Renderer.sun: color * intensity (0 when off), and the direction towards it
    float4 sun_radiance;
    float4 sun_direction;
}

struct Node {
    float4x4 world_matrix;
    uint material_id;
    uint mesh_id;
    // first bone of the node's palette when skinned
    uint attachment_data_index;
    uint flags;
    // first of the node's skinned vertices when skinned
    uint skin_vertex_base;
    uint _node_pad0;
    uint _node_pad1;
    uint _node_pad2;
}

struct MeshData {
    float3 aabb_min;
    uint index_count;
    float3 aabb_max;
    uint first_index;
    int vertex_offset;
    uint skinning_offset;
    uint flags;
    uint vertex_count;
}

// render.Material: a custom material reads params, and any other field it likes
struct Material {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    // MATERIAL_CUSTOM: the user shader drawing it
    uint shader;
    float4 base_color_factor;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
    // MaterialType
    uint material_type;
    // a .CUSTOM shader's own values
    float4 params[4];
}

struct Light {
    float3 color;
    float intensity;
    float radius;
    float angle_inner;
    float angle_outer;
    uint light_type;
    uint cast_shadow;
}

// Where a light is attached.
struct LightPlacement {
    uint light;
    uint node;
    // view index of the first shadow face, 0 for none
    uint shadow_map;
}

struct SkinningData {
    uint4 joints;
    float4 weights;
}

// A vertex the skinning pass deformed (render's SkinnedVertex); w of position and normal is unused.
struct SkinnedVertex {
    float4 position;
    float4 normal;
    float4 tangent;
}

// A draw batch: the nodes drawing one mesh with one material (render's Batch).
struct Batch {
    uint mesh_id;
    uint material_id;
    // where the batch's instances start in a draw list's instance array
    uint first_instance;
    // the nodes in it
    uint capacity;
}

// Indexed draws use all five words; non-indexed ones the first four.
struct DrawCommand {
    uint index_count;
    uint instance_count;
    uint first_index;
    int vertex_offset;
    uint first_instance;
}

// The vertex index as gl_VertexIndex / @builtin(vertex_index): SV_VertexID would subtract the
// draw's first vertex on Vulkan.
#if BACKEND_WGPU
#define VERTEX_ID SV_VertexID
#else
#define VERTEX_ID SV_VulkanVertexID
#endif

// The pass's per-draw words: a push constant on Vulkan, the uniform ring on wgpu.
#if BACKEND_WGPU
#define PUSH_BLOCK(T, name) [vk::binding(0, 2)] ConstantBuffer<T> name;
#else
#define PUSH_BLOCK(T, name) [vk::push_constant] ConstantBuffer<T> name;
#endif

// A scene buffer of the pass: its binding on Vulkan (render's table index) and on wgpu (its
// position in the pass's ScenePass).
#if BACKEND_WGPU
#define SCENE_BUFFER(T, name, vulkan_binding, wgpu_binding) [vk::binding(wgpu_binding, 0)] StructuredBuffer<T> name;
#define SCENE_BUFFER_RW(T, name, vulkan_binding, wgpu_binding) [vk::binding(wgpu_binding, 0)] RWStructuredBuffer<T> name;
#else
#define SCENE_BUFFER(T, name, vulkan_binding, wgpu_binding) [vk::binding(vulkan_binding, 0)] StructuredBuffer<T> name;
#define SCENE_BUFFER_RW(T, name, vulkan_binding, wgpu_binding) [vk::binding(vulkan_binding, 0)] RWStructuredBuffer<T> name;
#endif

SCENE_BUFFER(View, views, 0, 0)

#if BACKEND_WGPU
[vk::binding(1, 2)] SamplerState nearest_clamp;
[vk::binding(2, 2)] SamplerState linear_clamp;
[vk::binding(3, 2)] SamplerState nearest_repeat;
[vk::binding(4, 2)] SamplerState linear_repeat;
// bilinear depth comparison for shadow maps
[vk::binding(5, 2)] SamplerComparisonState shadow_compare;
#else
[vk::binding(1, TEXTURES_SET)] SamplerState samplers[];
#endif

SamplerState sampler_of(uint index)
{
#if BACKEND_WGPU
    switch (index) {
    case SAMPLER_NEAREST_CLAMP: return nearest_clamp;
    case SAMPLER_LINEAR_CLAMP: return linear_clamp;
    case SAMPLER_NEAREST_REPEAT: return nearest_repeat;
    default: return linear_repeat;
    }
#else
    return samplers[NonUniformResourceIndex(index)];
#endif
}

// Positions are computed in Vulkan's clip space (render's projections put y down); WebGPU's
// clip y points up, so every vertex shader outputs through here. Framebuffer coordinates, and
// so every uv, then match on both.
float4 clip_output(float4 p)
{
#if BACKEND_WGPU
    return float4(p.x, -p.y, p.z, p.w);
#else
    return p;
#endif
}

// A clip-space position outside the clip volume: a vertex that draws nothing.
static const float4 CLIP_DISCARD = float4(2.0, 2.0, 2.0, 1.0);

// The rotation and scale of a transform.
float3x3 mat3_of(float4x4 m)
{
    return float3x3(m[0].xyz, m[1].xyz, m[2].xyz);
}

// Where a direction lands on an equirectangular image.
float2 dir_to_equirect_uv(float3 dir)
{
    float u = atan2(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
    return float2(u, v);
}

// Schlick's Fresnel, damped by roughness for the image-based light.
float3 fresnel_schlick_roughness(float cos_theta, float3 f0, float roughness)
{
    return f0 + (max(float3(1.0 - roughness), f0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

// Two halves packed in a word, low half first (GLSL unpackHalf2x16): f16tof32 would need the
// Float16 and Int16 capabilities on Vulkan.
float2 unpack_half2(uint v)
{
#if BACKEND_WGPU
    return float2(f16tof32(v & 0xffff), f16tof32(v >> 16));
#else
    return spirv_asm { result:$$float2 = OpExtInst glsl450 UnpackHalf2x16 $v };
#endif
}
