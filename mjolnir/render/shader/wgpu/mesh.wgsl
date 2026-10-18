// What the vertex and fragment shaders of mesh materials share (scene group MESH): the scene
// buffers, the push, the vertex stream and the varyings. mesh_vertex.wgsl is the vertex shader.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(2) var<storage, read> meshes: array<MeshData>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;
// what the skinning pass wrote (skin.wgsl)
@group(0) @binding(4) var<storage, read> skinned: array<SkinnedVertex>;

struct MeshPush {
    camera_index: u32,
}
@group(2) @binding(0) var<uniform> u: MeshPush;

struct VertexIn {
    @builtin(vertex_index) vertex_index: u32,
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
    @location(3) uv: vec2f,
    @location(4) tangent: vec4f,
    // the draw's node (the candidate list, instance step)
    @location(5) node_index: u32,
}

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) position: vec3f,
    @location(1) color: vec4f,
    @location(2) normal: vec3f,
    @location(3) uv: vec2f,
    @location(4) tangent: vec4f,
    @location(5) @interpolate(flat) node_index: u32,
}
