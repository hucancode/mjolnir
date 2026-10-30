// The interface of a user material shader (render.material_shader_create): the scene buffers it
// reads, the material's textures and the mesh vertex stage's outputs. A custom material is drawn
// in the forward pass over the lit image, depth-tested and writing depth unless its shader was
// made with depth_write = false. Read your own values from node_material(v).params
// (render.Material.params), the time from camera_view().time, the sun from scene_sun() and the
// image size from camera_view().extent.
//
//     #include "material.slang"
//     [shader("fragment")]
//     float4 fs_main(VertexOut v) : SV_Target0
//     {
//         Material m = node_material(v);
//         float pulse = 0.5 + 0.5 * sin(camera_view().time * m.params[0].x);
//         return m.base_color_factor * pulse;
//     }
//
// A vertex shader that moves the mesh's vertices defines CUSTOM_VERTEX before including this, is
// `VertexOut vs_main(VertexIn v)` and ends with
// material_vertex(v, position, normal), position and normal in model space. Compile with
// slangc -I <this directory> for each backend (see the Makefile).
#pragma once
#include "mesh.slang"

static const uint TEXTURE_ALBEDO = 0;
static const uint TEXTURE_METALLIC_ROUGHNESS = 1;
static const uint TEXTURE_NORMAL = 2;
static const uint TEXTURE_EMISSIVE = 3;

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D albedo_texture;
[vk::binding(1, 1)] Texture2D metallic_roughness_texture;
[vk::binding(2, 1)] Texture2D normal_texture;
[vk::binding(3, 1)] Texture2D emissive_texture;
#else
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
#endif

SCENE_BUFFER(Light, lights, 10, 7)

// The sun as a custom material sees it: the brightest visible directional light. toward points
// towards it; radiance is its color * intensity, 0 without one.
struct Sun {
    float3 toward;
    float3 radiance;
}

Sun scene_sun()
{
    Sun sun;
    sun.toward = float3(0.0, 1.0, 0.0);
    sun.radiance = float3(0.0);
    if (mesh_push.sun_light == 0) return sun;
    Light light = lights[mesh_push.sun_light];
    float4x4 m = nodes[mesh_push.sun_node].world_matrix;
    // the light shines along its node's -Z
    float3 z = float3(m[0][2], m[1][2], m[2][2]);
    if (dot(z, z) > 1e-6) sun.toward = normalize(z);
    sun.radiance = light.color * light.intensity;
    return sun;
}

// The material of the drawn node.
Material node_material(VertexOut v)
{
    return materials[nodes[v.node_index].material_id];
}

// The material of the vertex's node.
Material vertex_material(VertexIn v)
{
    return materials[nodes[v.node_index].material_id];
}

// The material's texture `slot` (TEXTURE_*) at uv, repeating; white for a slot without one.
float4 material_texture(Material m, uint slot, float2 uv)
{
#if BACKEND_WGPU
    // a missing texture is bound white
    switch (slot) {
    case TEXTURE_ALBEDO: return albedo_texture.Sample(linear_repeat, uv);
    case TEXTURE_METALLIC_ROUGHNESS: return metallic_roughness_texture.Sample(linear_repeat, uv);
    case TEXTURE_NORMAL: return normal_texture.Sample(linear_repeat, uv);
    default: return emissive_texture.Sample(linear_repeat, uv);
    }
#else
    uint index = m.albedo_index;
    if (slot == TEXTURE_METALLIC_ROUGHNESS) index = m.metallic_roughness_index;
    if (slot == TEXTURE_NORMAL) index = m.normal_index;
    if (slot == TEXTURE_EMISSIVE) index = m.emissive_index;
    if (index == NO_TEXTURE) return float4(1.0);
    return textures[NonUniformResourceIndex(index)].Sample(samplers[SAMPLER_LINEAR_REPEAT], uv);
#endif
}

// The vertex at model-space position and normal, moved by its node and seen by the camera.
VertexOut material_vertex(VertexIn v, float3 position, float3 normal)
{
    float4x4 world = nodes[v.node_index].world_matrix;
    float4 world_position = mul(world, float4(position, 1.0));
    VertexOut o;
    o.normal = normalize(mul(mat3_of(world), normal));
    o.tangent = float4(normalize(mul(mat3_of(world), v.tangent.xyz)), v.tangent.w);
    o.uv = v.uv;
    o.color = v.color;
    o.position = world_position.xyz;
    o.node_index = v.node_index;
    o.clip = clip_output(mul(camera_view().view_projection, world_position));
    return o;
}

// The engine's vertex stage, unless the shader defines CUSTOM_VERTEX and writes its own vs_main.
#ifndef CUSTOM_VERTEX
#include "mesh_vertex.slang"
#endif
