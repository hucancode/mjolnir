// Advances every live particle and appends it to the alive list, whose header is the indirect
// draw: Vulkan draws one instance per live particle, growing vertex_count with one atomic per
// group; wgpu grows the instance count (word 1) the same way, the vertex count stays six.
#include "common.slang"

static const uint MAX_PARTICLES = 65536;
static const uint MAX_FORCE_FIELDS = 32;
static const float3 GRAVITY = float3(0.0, -9.8, 0.0);

struct Particle {
    float3 position;
    float size_start;
    float3 velocity;
    float size_end;
    float4 color_start;
    float4 color_end;
    float life;
    float max_life;
    float weight;
    uint texture_index;
}

struct ForceField {
    float tangent_strength;
    float strength;
    float area_of_effect;
}

struct ForceFieldPlacement {
    uint force_field;
    uint node;
}


SCENE_BUFFER(Node, nodes, 1, 0)
SCENE_BUFFER(ForceField, force_fields, 7, 1)
SCENE_BUFFER_RW(Particle, particles, 8, 2)
// the indirect draw (vertex count, instance count, first vertex, first instance), then the
// alive particles' indices
#if BACKEND_WGPU
[vk::binding(3, 0)] RWStructuredBuffer<Atomic<uint>> alive_words;
#else
[vk::binding(9, 0)] RWStructuredBuffer<Atomic<uint>> alive_words;
#endif
SCENE_BUFFER(ForceFieldPlacement, placements, 20, 4)

struct ParticleSystemParams {
    uint emitter_placement_count;
    uint force_field_placement_count;
    float delta_time;
    uint frame_counter;
    uint emit_total;
    uint emit_cursor;
}
PUSH_BLOCK(ParticleSystemParams, params)

// Advance live particle i; returns whether it is still alive.
bool simulate(uint i)
{
    float3 p = particles[i].position;
    float3 v = particles[i].velocity;
    uint n = min(params.force_field_placement_count, MAX_FORCE_FIELDS);
    for (uint f = 0; f < n; f++) {
        ForceFieldPlacement placed = placements[f];
        // free rows and destroyed force fields are zero: area_of_effect 0
        ForceField ff = force_fields[placed.force_field];
        if (ff.area_of_effect <= 0.0 || placed.node == 0) { continue; }
        float4x4 ff_world = nodes[placed.node].world_matrix;
        float3 ff_pos = float3(ff_world[0][3], ff_world[1][3], ff_world[2][3]);
        float dist = length(p - ff_pos);
        if (dist > ff.area_of_effect) { continue; }
        float effect = 1.0 - clamp(dist / ff.area_of_effect, 0.0, 1.0);
        float3 dir = (ff_pos - p) / max(dist, 1e-4);
        float3 reference = lerp(float3(0.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), step(0.99, abs(dir.y)));
        float3 tangent = normalize(cross(reference, dir));
        float3 force = dir * ff.strength + tangent * ff.tangent_strength;
        v += force * effect * params.delta_time;
    }
    v += GRAVITY * particles[i].weight * params.delta_time;
    // limit speed (branchless div-by-zero guard)
    float speed = length(v);
    v *= min(speed, 5.0) / max(speed, 1e-6);
    particles[i].velocity = v;
    particles[i].position = p + v * params.delta_time;
    float life = particles[i].life - params.delta_time;
    particles[i].life = life;
    return life > 0.0;
}

// live particles of this group, appended to the alive list with one global atomic per group
groupshared Atomic<uint> group_alive;
groupshared uint group_first;

[shader("compute")]
[numthreads(256, 1, 1)]
void main(uint3 gid : SV_DispatchThreadID, uint local : SV_GroupIndex)
{
    uint i = gid.x;
    if (local == 0) {
        group_alive.store(0);
    }
    GroupMemoryBarrierWithGroupSync();
    bool live = i < MAX_PARTICLES && particles[i].life > 0.0;
    uint slot = 0;
    if (live) {
        live = simulate(i);
        if (live) {
            slot = group_alive.add(1);
        }
    }
    GroupMemoryBarrierWithGroupSync();
    if (local == 0) {
#if BACKEND_WGPU
        group_first = alive_words[1].add(group_alive.load());
#else
        group_first = alive_words[0].add(group_alive.load());
#endif
    }
    GroupMemoryBarrierWithGroupSync();
    if (live) {
        alive_words[4 + group_first + slot].store(i);
    }
}
