// The vertex shader of materials drawn without an index buffer (wireframe, random color):
// each vertex pulls its index from the index buffer and its vertex from the vertex buffer,
// both bound as storage (scene group MESH), skinned like mesh.wgsl. The draw is
// non-indexed from first vertex 0; pulled_index maps vertex_index to the k-th index of the
// mesh (it is declared by the material's file).

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(2) var<storage, read> meshes: array<Mesh>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;
// what the skinning pass wrote (skin.wgsl)
@group(0) @binding(4) var<storage, read> skinned: array<SkinnedVertex>;
// Vertex as 16 floats: position 0..3, normal 3..6, color 6..10, uv 10..12, tangent 12..16
@group(0) @binding(5) var<storage, read> vertices: array<f32>;
@group(0) @binding(6) var<storage, read> indices: array<u32>;

struct MeshUniforms {
    camera_index: u32,
}
@group(2) @binding(0) var<uniform> u: MeshUniforms;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) position: vec3f,
    @location(1) color: vec4f,
    // the triangle of the vertex (gl_PrimitiveID of an indexed draw)
    @location(2) @interpolate(flat) primitive: u32,
    @location(5) @interpolate(flat) node_index: u32,
}

fn mat3_of(m: mat4x4f) -> mat3x3f {
    return mat3x3f(m[0].xyz, m[1].xyz, m[2].xyz);
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @location(5) node_index: u32) -> VertexOut {
    let camera = views[u.camera_index];
    let node = nodes[node_index];
    let mesh = meshes[node.mesh_id];
    let k = pulled_index(vertex_index);
    let vertex = i32(indices[mesh.first_index + k]) + mesh.vertex_offset;
    let base = u32(vertex) * 16u;
    var model_position = vec4f(vertices[base], vertices[base + 1u], vertices[base + 2u], 1.0);
    let color = vec4f(vertices[base + 6u], vertices[base + 7u], vertices[base + 8u], vertices[base + 9u]);
    if ((node.flags & NODE_FLAG_SKINNED) != 0u) {
        model_position = vec4f(skinned[node.skin_vertex_base + u32(vertex - mesh.vertex_offset)].position.xyz, 1.0);
    }
    let world_position = node.world_matrix * model_position;
    var out: VertexOut;
    out.position = world_position.xyz;
    out.color = color;
    out.primitive = k / 3u;
    out.node_index = node_index;
    out.clip = clip_output(camera.projection * camera.view * world_position);
    return out;
}
