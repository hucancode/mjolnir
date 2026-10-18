// The interface of your compute and draw shaders (render.compute_shader_create,
// render.draw_shader_create). Follows common.wgsl (View, the samplers nearest_clamp,
// linear_clamp, nearest_repeat, linear_repeat and clip_output); your source follows this.
// Declare:
//   struct Params, the fields of the params you stage, in the order of the Odin struct. It sits
//     in a uniform: use scalars and vec4f, as arrays and vec3f pad differently from Odin.
//   your bindings as @group(1) @binding(i), i the index in the shader's bindings: a buffer is
//     var<storage, read_write> in a compute shader and var<storage, read> in a draw shader, a
//     texture texture_2d<f32>, an image texture_storage_2d<FORMAT, write> (rgba8unorm,
//     rgba16float, r32float, as made).
//   compute: @compute @workgroup_size(...) fn main
//   draw: @vertex fn vs_main, outputting its position through clip_output, and @fragment fn
//     fs_main to @location(0), the camera's HDR lit image. MeshVertex is a mesh's vertex
//     (DrawState.mesh_vertices); without one, build vertices from @builtin(vertex_index).
// gpu.camera_index is the drawing camera (the main camera's in a compute shader):
// views[gpu.camera_index].view_projection, .position, .time, .sun_direction, ...

@group(0) @binding(0) var<storage, read> views: array<View>;

struct GpuPush {
    camera_index: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    params: Params,
}

@group(2) @binding(0) var<uniform> gpu: GpuPush;

struct MeshVertex {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
    @location(3) uv: vec2f,
    @location(4) tangent: vec4f,
}
