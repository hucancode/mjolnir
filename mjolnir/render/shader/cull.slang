// Vulkan: culls every node against a range of views in one dispatch: x covers nodes, y the
// views from params.first_view. A visible node is appended to list type * view.list_stride of
// the bindless draw lists view.draw_list, type its material type; list l keeps its count at
// counts[l] and its commands from l * view.list_capacity.
// wgpu: tests node i (x) against view first_view + y and, when it is visible, counts it in its
// batch's draw and lists it: draw list y of the slot's buffer. The buffer holds words:
// per list the count of visible opaque nodes, then per list max_batches indirect draws
// (cull_draws.slang writes all but their instance counts), then per list the node indices of
// each batch's visible instances, from the batch's first_instance.
#include "common.slang"

SCENE_BUFFER(Node, nodes, 1, 1)
SCENE_BUFFER(MeshData, meshes, 2, 2)
SCENE_BUFFER(Material, materials, 3, 3)

static const float DEPTH_BIAS = 0.0001;
// draw lists per view, one per material type (render.DRAW_LIST_HEADER)
static const uint DRAW_LIST_HEADER = 8;

#if BACKEND_WGPU
SCENE_BUFFER(Batch, batches, 0, 4)
SCENE_BUFFER(uint, node_batch, 0, 5)

struct BatchPush {
    uint node_count;
    uint first_view;
    // words
    uint instance_stride;
    uint draws_base;
    uint instances_base;
    uint max_batches;
    uint batch_count;
    // 1: a draw's first instance is where its batch's instances start (indirect first instance)
    uint first_instance;
}
PUSH_BLOCK(BatchPush, params)

[vk::binding(0, 3)] RWStructuredBuffer<Atomic<uint>> list;
[vk::binding(1, 3)] Texture2D pyramid;

Texture2D pyramid_of(View view)
{
    return pyramid;
}
#else

struct CullPush {
    uint node_count;
    uint first_view;
}
PUSH_BLOCK(CullPush, params)

[vk::binding(0, 1)] Texture2D textures[];

// bindless draw lists: DRAW_LIST_HEADER counts, then DrawCommands
[vk::binding(3, 1)] RWByteAddressBuffer draw_lists[];

Texture2D pyramid_of(View view)
{
    return textures[NonUniformResourceIndex(view.pyramid)];
}
#endif

bool in_view(View view, float3 center, float3 extent)
{
    for (int i = 0; i < 6; ++i) {
        float4 plane = view.planes[i];
        float distance = dot(plane.xyz, center) + plane.w;
        float radius = dot(abs(plane.xyz), extent);
        if (distance + radius < 0.0) {
            return false;
        }
    }
    return true;
}

// 2D Polyhedral Bounds of a Clipped, Perspective-Projected 3D Sphere: the uv box, false when
// the sphere crosses the near plane.
bool project_sphere(float3 center, float radius, float4x4 proj, float near, float far, out float4 aabb)
{
    aabb = float4(0);
    if (center.z - radius > -near) return false;
    if (center.z + radius < -far) return false;

    float3 c = float3(center.x, center.y, -center.z);
    float r = radius;
    float znear = near;

    if (c.z < r + znear) {
        return false;
    }

    float P00 = proj[0][0];
    float P11 = abs(proj[1][1]);

    float3 cr = c * r;
    float czr2 = c.z * c.z - r * r;

    float vx = sqrt(c.x * c.x + czr2);
    float minx = (vx * c.x - cr.z) / (vx * c.z + cr.x);
    float maxx = (vx * c.x + cr.z) / (vx * c.z - cr.x);

    float vy = sqrt(c.y * c.y + czr2);
    float miny = (vy * c.y - cr.z) / (vy * c.z + cr.y);
    float maxy = (vy * c.y + cr.z) / (vy * c.z - cr.y);

    aabb = float4(minx * P00, miny * P11, maxx * P00, maxy * P11);
    aabb = aabb.xwzy * float4(0.5, -0.5, 0.5, -0.5) + float4(0.5);
    aabb = clamp(aabb, 0.0, 1.0);

    return (aabb.z > aabb.x) && (aabb.w > aabb.y);
}

// Farthest depth of the 2x2 texels of mip `level` around uv, like a bilinear
// fetch reduced with MAX.
float max_depth(Texture2D pyramid_texture, float2 uv, int level)
{
    // from mip 0: lavapipe (wgpu) answers a runtime mip's size query with mip 0's size
    uint w, h, levels;
    pyramid_texture.GetDimensions(0, w, h, levels);
    int2 size = max(int2(w, h) >> level, int2(1));
    int2 i0 = int2(floor(uv * float2(size) - 0.5));
    int2 lo = clamp(i0, int2(0), size - 1);
    int2 hi = clamp(i0 + 1, int2(0), size - 1);
    return max(max(pyramid_texture.Load(int3(lo, level)).r, pyramid_texture.Load(int3(hi.x, lo.y, level)).r),
               max(pyramid_texture.Load(int3(lo.x, hi.y, level)).r, pyramid_texture.Load(int3(hi, level)).r));
}

// return true if the sphere is visible, false if occluded
bool occlusion_test(float3 center, float radius, View view)
{
    Texture2D pyramid_texture = pyramid_of(view);
    float4 view_center4 = mul(view.view, float4(center, 1.0));
    float3 view_center = view_center4.xyz;

    float4 aabb;
    if (!project_sphere(view_center, radius, view.projection, view.near, view.far, aabb)) {
        return true;
    }

    uint w, h, levels;
    pyramid_texture.GetDimensions(0, w, h, levels);
    float2 pyramid_size = float2(w, h);
    float width = (aabb.z - aabb.x) * pyramid_size.x;
    float height = (aabb.w - aabb.y) * pyramid_size.y;
    float level = ceil(log2(max(width, height)));
    level = clamp(level, 0.0, float(levels - 1));

    float2 sample_uv = (aabb.xy + aabb.zw) * 0.5;
    float occluder_depth = max_depth(pyramid_texture, sample_uv, int(level));

    float object_near_z = view_center.z + radius;
    float4 clip_pos = mul(view.projection, float4(0, 0, object_near_z, 1.0));
    float object_depth = clip_pos.z / clip_pos.w;

    return object_depth < (occluder_depth + DEPTH_BIAS);
}

// The part of a node's culling the backends share, after their own early outs.
bool in_frustum_and_visible(View view, Node node, uint type)
{
    MeshData mesh = meshes[node.mesh_id];
    float4x4 world = node.world_matrix;
    float3 local_center = 0.5 * (mesh.aabb_min + mesh.aabb_max);
    float3 local_extent = 0.5 * (mesh.aabb_max - mesh.aabb_min);
    float4 world_center4 = mul(world, float4(local_center, 1.0));
    float3 world_center = world_center4.xyz / max(world_center4.w, 1e-6);
    float3x3 abs_world3 = abs(mat3_of(world));
    float3 world_extent = mul(abs_world3, local_extent);

    if (!in_view(view, world_center, world_extent)) return false;
    if (((view.occlusion_mask >> type) & 1) != 0 &&
        !occlusion_test(world_center, length(world_extent), view)) {
        return false;
    }
    return true;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 gid : SV_DispatchThreadID, uint3 wid : SV_GroupID)
{
#if BACKEND_WGPU
    uint i = gid.x;
    if (i >= params.node_count) { return; }
    uint id = node_batch[i];
    if (id == 0) { return; }
    View view = views[params.first_view + wid.y];
    Node node = nodes[i];
    uint material_type = materials[node.material_id].material_type;
    // empty view (free camera slot): accepts nothing
    if (view.type_mask == 0) { return; }
    if ((node.flags & view.require_flags) != view.require_flags) { return; }
    if (((view.hidden_layers >> node.layer) & 1) != 0) { return; }
    if (material_type >= DRAW_LIST_HEADER || ((view.type_mask >> material_type) & 1) == 0) { return; }
    if (!in_frustum_and_visible(view, node, material_type)) { return; }
    Batch batch = batches[id];
    uint slot = list[params.draws_base + (wid.y * params.max_batches + id) * 5 + 1].add(1);
    if (slot < batch.capacity) {
        list[params.instances_base + wid.y * params.instance_stride + batch.first_instance + slot].store(i);
    }
    if (material_type == MATERIAL_PBR) {
        list[wid.y].add(1);
    }
#else
    uint node_id = gid.x;
    if (node_id >= params.node_count) return;
    View view = views[params.first_view + wid.y];
    // empty view (free camera slot): accepts nothing
    if (view.type_mask == 0) return;

    Node node = nodes[node_id];
    // 0 is none
    if (node.mesh_id == 0 || node.material_id == 0) return;
    if ((node.flags & view.require_flags) != view.require_flags) return;
    if (((view.hidden_layers >> node.layer) & 1) != 0) return;
    Material material = materials[node.material_id];
    uint type = material.material_type;
    // a type past every draw list draws nowhere
    if (type >= DRAW_LIST_HEADER || ((view.type_mask >> type) & 1) == 0) return;

    if (!in_frustum_and_visible(view, node, type)) return;

    MeshData mesh = meshes[node.mesh_id];
    DrawCommand cmd;
    cmd.index_count = mesh.index_count;
    cmd.instance_count = 1;
    cmd.first_index = mesh.first_index;
    cmd.vertex_offset = mesh.vertex_offset;
    cmd.first_instance = node_id | view.instance_tag;

    uint list = type * view.list_stride;
    uint draw_index;
    draw_lists[view.draw_list].InterlockedAdd(list * 4, 1, draw_index);
    if (draw_index < view.list_capacity) {
        uint at = DRAW_LIST_HEADER * 4 + (list * view.list_capacity + draw_index) * 20;
        draw_lists[view.draw_list].Store4(at, uint4(cmd.index_count, cmd.instance_count, cmd.first_index, asuint(cmd.vertex_offset)));
        draw_lists[view.draw_list].Store(at + 16, cmd.first_instance);
    }
#endif
}
