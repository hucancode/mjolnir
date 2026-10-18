// The interface of your compute and draw shaders (render.compute_shader_create,
// render.draw_shader_create): the views, the samplers and textures, and the push block. Before
// including this, declare struct Params, the fields of the params you stage in the order of the
// Odin struct (std430: prefer scalars and vec4, as a vec3 takes 16 bytes unless a float follows
// it), and, in a vertex shader that reads a mesh's vertices (DrawState.mesh_vertices), define
// GPU_MESH_VERTEX for in_position, in_normal, in_color, in_uv and in_tangent.
// Your bindings are set 1, binding i the index in the shader's bindings: a buffer is a buffer
// block (readonly in a draw shader), a texture a texture2D, an image an image2D of its format
// (rgba8, rgba16f, r32f, as made), writeonly. A draw writes out location 0, the camera's HDR lit
// image. gpu.camera_index is the drawing camera (the main camera's in a compute shader):
// views[gpu.camera_index].view_projection, .position, .time, .sun_direction, ...
//
//     #version 450
//     struct Params { float speed; uint count; };
//     #include "gpu.glsl"
//     layout(local_size_x = 64) in;
//     layout(set = 1, binding = 0) buffer Points { vec4 points[]; };
//     void main() {
//         uint i = gl_GlobalInvocationID.x;
//         if (i < gpu.params.count) points[i].y += gpu.params.speed;
//     }
//
// Compile with glslc --target-env=vulkan1.3 -I <this directory>.

#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

struct View {
    mat4 view;
    mat4 projection;
    mat4 view_projection;
    mat4 inv_view_projection;
    vec4 planes[6];
    vec4 position; // world position of the camera
    vec2 extent;
    float near;
    float far;
    // the rest is render's own; don't rely on it
    uint images[6];
    uint pyramid;
    uint occlusion_mask;
    uint list_stride;
    uint type_mask;
    uint require_flags;
    uint instance_tag;
    uint layer;
    uint draw_list;
    uint list_capacity;
    float time; // render's clock in seconds
    vec4 sun_radiance; // Renderer.sun: color * intensity, 0 when off
    vec4 sun_direction; // towards the sun
};

layout(set = 0, binding = 0) readonly buffer GpuViews {
    View views[];
};

// every texture, by TextureHandle, and the samplers
layout(set = 2, binding = 0) uniform texture2D textures[];
layout(set = 2, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform GpuPush {
    uint camera_index;
    uint _gpu_pad0;
    uint _gpu_pad1;
    uint _gpu_pad2;
    Params params;
} gpu;

#ifdef GPU_MESH_VERTEX
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec4 in_tangent;
#endif
