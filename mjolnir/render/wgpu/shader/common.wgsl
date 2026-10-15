// Declarations every shader of the wgpu backend starts with (pipelines prepend this file):
// render's table entries, the frame group's samplers, and the clip-space convention.
// Bindings: @group(0) the pass's scene buffers (ScenePass in pipeline.odin, in its order),
// @group(1) its textures (GroupLayout), @group(2) binding 0 its uniforms, 1.. the samplers.

const PI: f32 = 3.14159265359;

// texture handle of a material slot without a texture
const NO_TEXTURE: u32 = 0u;

// MaterialType
const MATERIAL_PBR: u32 = 0u;
const MATERIAL_TRANSPARENT: u32 = 1u;
const MATERIAL_WIREFRAME: u32 = 2u;
const MATERIAL_RANDOM_COLOR: u32 = 3u;
const MATERIAL_SPRITE: u32 = 4u;

// LightType
const LIGHT_POINT: u32 = 0u;
const LIGHT_SPOT: u32 = 1u;
const LIGHT_DIRECTIONAL: u32 = 2u;
const LIGHT_AMBIENT: u32 = 3u;

// node flags
const NODE_FLAG_VISIBLE: u32 = 1u;
const NODE_FLAG_CASTS_SHADOW: u32 = 2u;
// the node holds a bone range; only set on a skinned mesh
const NODE_FLAG_SKINNED: u32 = 4u;

struct View {
    view: mat4x4f,
    projection: mat4x4f,
    view_projection: mat4x4f,
    // rebuilds world positions from depth
    inv_view_projection: mat4x4f,
    // normalized, pointing inward
    planes: array<vec4f, 6>,
    position: vec4f,
    extent: vec2f,
    near: f32,
    far: f32,
    // render's texture handles, by AttachmentType (bound through group 1 here)
    attachments: array<u32, 6>,
    pyramid: u32,
    // bit t: material type t is tested against the pyramid
    occlusion_mask: u32,
    list_stride: u32,
    // bit t: material type t is drawn
    type_mask: u32,
    // node flags a drawn node has
    require_flags: u32,
    instance_tag: u32,
    layer: u32,
    draw_list: u32,
    list_capacity: u32,
    _pad0: u32,
}

struct Node {
    world_matrix: mat4x4f,
    material_id: u32,
    mesh_id: u32,
    // first bone of the node's palette when skinned
    attachment_data_index: u32,
    flags: u32,
}

struct Mesh {
    aabb_min: vec3f,
    index_count: u32,
    aabb_max: vec3f,
    first_index: u32,
    vertex_offset: i32,
    skinning_offset: u32,
    flags: u32,
    vertex_count: u32,
}

struct Material {
    albedo_index: u32,
    metallic_roughness_index: u32,
    normal_index: u32,
    emissive_index: u32,
    metallic_value: f32,
    roughness_value: f32,
    emissive_value: f32,
    _pad0: u32,
    base_color_factor: vec4f,
    frame_columns: u32,
    frame_rows: u32,
    frame_index: u32,
    material_type: u32,
}

struct Light {
    // rgb, a = intensity
    color: vec4f,
    position: vec3f,
    radius: f32,
    direction: vec3f,
    angle_inner: f32,
    angle_outer: f32,
    // view index of the first shadow face, 0 for none
    shadow_map: u32,
    // world size of a shadow texel per unit of view depth, for point and spot
    shadow_texel: f32,
    _pad0: u32,
}

struct Skinning {
    joints: vec4u,
    weights: vec4f,
}

// A draw batch: the nodes drawing one mesh with one material (render's Batch).
struct Batch {
    mesh_id: u32,
    material_id: u32,
    // where the batch's instances start in a draw list's instance array
    first_instance: u32,
    // the nodes in it
    capacity: u32,
}

// Indexed draws use all five words; non-indexed ones the first four.
struct DrawCommand {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
}

@group(2) @binding(1) var nearest_clamp: sampler;
@group(2) @binding(2) var linear_clamp: sampler;
@group(2) @binding(3) var nearest_repeat: sampler;
@group(2) @binding(4) var linear_repeat: sampler;
// bilinear depth comparison for shadow maps
@group(2) @binding(5) var shadow_compare: sampler_comparison;

// Positions are computed in Vulkan's clip space (render's projections put y down); WebGPU's
// clip y points up, so every vertex shader outputs through here. Framebuffer coordinates,
// and so every uv and gl_FragCoord-style computation, then match Vulkan's.
fn clip_output(p: vec4f) -> vec4f {
    return vec4f(p.x, -p.y, p.z, p.w);
}

// A clip-space position outside the clip volume: a vertex that draws nothing.
const CLIP_DISCARD: vec4f = vec4f(2.0, 2.0, 2.0, 1.0);
