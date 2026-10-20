// The interface of your compute and draw shaders (render.compute_shader_create,
// render.draw_shader_create): the views, the samplers, the textures and the push block. Declare
// struct Params, the fields of the params you stage in the order of the Odin struct (std430:
// prefer scalars and float4, a float3 takes 16 bytes unless a float follows it), before
// including this. Your bindings are set 1, binding i the index in the shader's bindings: a
// buffer is a StructuredBuffer (RWStructuredBuffer in a compute shader), a texture a Texture2D,
// an image an RWTexture2D<float4> of its format (rgba8, rgba16f, r32f, as made). A draw writes
// SV_Target0, the camera's HDR lit image. gpu.camera_index is the drawing camera (the main
// camera's in a compute shader): views[gpu.camera_index].view_projection, .position, .time, ...
//
//     struct Params { float speed; uint count; }
//     #include "gpu.slang"
//     [vk::binding(0, 1)] RWStructuredBuffer<float4> points;
//     [shader("compute")][numthreads(64, 1, 1)]
//     void main(uint3 id : SV_DispatchThreadID) { if (id.x < gpu.params.count) points[id.x].y += gpu.params.speed; }
#pragma once
#define TEXTURES_SET 2
#include "common.slang"

struct GpuPush {
    uint camera_index;
    uint _gpu_pad0;
    uint _gpu_pad1;
    uint _gpu_pad2;
    Params params;
}
PUSH_BLOCK(GpuPush, gpu)

#if !BACKEND_WGPU
// every texture, by TextureHandle
[vk::binding(0, 2)] Texture2D textures[];
#endif

// A mesh's vertex (DrawState.mesh_vertices); without one, build vertices from SV_VertexID.
struct MeshVertex {
    [vk::location(0)] float3 position : POSITION;
    [vk::location(1)] float3 normal : NORMAL;
    [vk::location(2)] float4 color : COLOR0;
    [vk::location(3)] float2 uv : TEXCOORD0;
    [vk::location(4)] float4 tangent : TANGENT;
}
