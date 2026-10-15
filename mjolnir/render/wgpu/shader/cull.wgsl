// Tests node i (x) against view first_view + y and, when it is visible, counts it in its
// batch's draw and lists it: draw list y of the slot's buffer. The buffer holds words:
// per list the count of visible opaque nodes, then per list max_batches indirect draws
// (cull_draws.wgsl writes all but their instance counts), then per list the node indices of
// each batch's visible instances, from the batch's first_instance.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(2) var<storage, read> meshes: array<Mesh>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;
@group(0) @binding(4) var<storage, read> batches: array<Batch>;
@group(0) @binding(5) var<storage, read> node_batch: array<u32>;

struct CullUniforms {
    node_count: u32,
    first_view: u32,
    // words
    instance_stride: u32,
    draws_base: u32,
    instances_base: u32,
    max_batches: u32,
    batch_count: u32,
    _pad: u32,
}
@group(2) @binding(0) var<uniform> u: CullUniforms;

@group(3) @binding(0) var<storage, read_write> list: array<atomic<u32>>;
@group(3) @binding(1) var pyramid: texture_2d<f32>;

const DEPTH_BIAS: f32 = 0.0001;

fn in_view(view: View, center: vec3f, extent: vec3f) -> bool {
    for (var i = 0; i < 6; i++) {
        let plane = view.planes[i];
        if (dot(plane.xyz, center) + plane.w + dot(abs(plane.xyz), extent) < 0.0) {
            return false;
        }
    }
    return true;
}

// 2D Polyhedral Bounds of a Clipped, Perspective-Projected 3D Sphere: the uv box, false when
// the sphere crosses the near plane.
fn project_sphere(center: vec3f, radius: f32, proj: mat4x4f, near: f32, far: f32, aabb: ptr<function, vec4f>) -> bool {
    if (center.z - radius > -near) { return false; }
    if (center.z + radius < -far) { return false; }
    let c = vec3f(center.x, center.y, -center.z);
    let r = radius;
    if (c.z < r + near) { return false; }
    let p00 = proj[0][0];
    let p11 = abs(proj[1][1]);
    let cr = c * r;
    let czr2 = c.z * c.z - r * r;
    let vx = sqrt(c.x * c.x + czr2);
    let minx = (vx * c.x - cr.z) / (vx * c.z + cr.x);
    let maxx = (vx * c.x + cr.z) / (vx * c.z - cr.x);
    let vy = sqrt(c.y * c.y + czr2);
    let miny = (vy * c.y - cr.z) / (vy * c.z + cr.y);
    let maxy = (vy * c.y + cr.z) / (vy * c.z - cr.y);
    var box = vec4f(minx * p00, miny * p11, maxx * p00, maxy * p11);
    box = box.xwzy * vec4f(0.5, -0.5, 0.5, -0.5) + vec4f(0.5);
    box = clamp(box, vec4f(0.0), vec4f(1.0));
    *aabb = box;
    return box.z > box.x && box.w > box.y;
}

// Farthest depth of the 2x2 texels of mip `level` around uv, like a bilinear fetch reduced
// with max.
fn max_depth(uv: vec2f, level: i32) -> f32 {
    let size = vec2i(textureDimensions(pyramid, level));
    let i0 = vec2i(floor(uv * vec2f(size) - 0.5));
    let lo = clamp(i0, vec2i(0), size - 1);
    let hi = clamp(i0 + 1, vec2i(0), size - 1);
    return max(
        max(textureLoad(pyramid, lo, level).r, textureLoad(pyramid, vec2i(hi.x, lo.y), level).r),
        max(textureLoad(pyramid, vec2i(lo.x, hi.y), level).r, textureLoad(pyramid, hi, level).r),
    );
}

// false when the sphere is behind the depth the pyramid holds
fn occlusion_test(center: vec3f, radius: f32, view: View) -> bool {
    let view_center = (view.view * vec4f(center, 1.0)).xyz;
    var aabb: vec4f;
    if (!project_sphere(view_center, radius, view.projection, view.near, view.far, &aabb)) {
        return true;
    }
    let size = vec2f(textureDimensions(pyramid, 0));
    let width = (aabb.z - aabb.x) * size.x;
    let height = (aabb.w - aabb.y) * size.y;
    let level = clamp(ceil(log2(max(width, height))), 0.0, f32(textureNumLevels(pyramid) - 1u));
    let occluder = max_depth((aabb.xy + aabb.zw) * 0.5, i32(level));
    let clip = view.projection * vec4f(0.0, 0.0, view_center.z + radius, 1.0);
    return clip.z / clip.w < occluder + DEPTH_BIAS;
}

fn visible(view: View, node: Node, material_type: u32) -> bool {
    // empty view (free camera slot): accepts nothing
    if (view.type_mask == 0u) { return false; }
    if ((node.flags & view.require_flags) != view.require_flags) { return false; }
    if (((view.type_mask >> material_type) & 1u) == 0u) { return false; }
    let mesh = meshes[node.mesh_id];
    let world = node.world_matrix;
    let local_center = 0.5 * (mesh.aabb_min + mesh.aabb_max);
    let local_extent = 0.5 * (mesh.aabb_max - mesh.aabb_min);
    let world_center4 = world * vec4f(local_center, 1.0);
    let world_center = world_center4.xyz / max(world_center4.w, 1e-6);
    let abs_world = mat3x3f(abs(world[0].xyz), abs(world[1].xyz), abs(world[2].xyz));
    let world_extent = abs_world * local_extent;
    if (!in_view(view, world_center, world_extent)) { return false; }
    if (((view.occlusion_mask >> material_type) & 1u) != 0u && !occlusion_test(world_center, length(world_extent), view)) {
        return false;
    }
    return true;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3u, @builtin(workgroup_id) wid: vec3u) {
    let i = gid.x;
    if (i >= u.node_count) { return; }
    let id = node_batch[i];
    if (id == 0u) { return; }
    let view = views[u.first_view + wid.y];
    let node = nodes[i];
    let material_type = materials[node.material_id].material_type;
    if (!visible(view, node, material_type)) { return; }
    let batch = batches[id];
    let slot = atomicAdd(&list[u.draws_base + (wid.y * u.max_batches + id) * 5u + 1u], 1u);
    if (slot < batch.capacity) {
        atomicStore(&list[u.instances_base + wid.y * u.instance_stride + batch.first_instance + slot], i);
    }
    if (material_type == MATERIAL_PBR) {
        atomicAdd(&list[wid.y], 1u);
    }
}
