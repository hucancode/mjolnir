// Spawns the frame's new particles: one thread per new particle, written to the ring slot
// after the previous one; once the ring is full new particles overwrite the oldest.
#include "common.slang"

static const uint MAX_PARTICLES = 65536;

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

struct Emitter {
    float3 initial_velocity;
    float velocity_spread;
    float4 color_start;
    float4 color_end;
    float position_spread;
    float size_start;
    float size_end;
    float particle_lifetime;
    float weight;
    float weight_spread;
    // read by render, which counts each frame's new particles
    float emission_rate;
    uint texture;
}

// Where an emitter is attached; placement i emits the frame's new particles
// [emit_first, the next placement's emit_first).
struct EmitterPlacement {
    uint emitter;
    uint node;
    uint emit_first;
}

SCENE_BUFFER(Node, nodes, 1, 0)
SCENE_BUFFER(Emitter, emitters, 6, 1)
SCENE_BUFFER_RW(Particle, particles, 8, 2)
SCENE_BUFFER(EmitterPlacement, placements, 19, 3)

struct ParticleSystemParams {
    uint emitter_placement_count;
    uint force_field_placement_count;
    float delta_time;
    uint frame_counter;
    // new particles this frame
    uint emit_total;
    // ring slot of the first one
    uint emit_cursor;
}
PUSH_BLOCK(ParticleSystemParams, params)

// PCG hash: independent, well-distributed 32-bit outputs even when inputs differ by 1, so
// spawn positions do not cluster when the emitter index dominates the seed.
uint pcg_hash(uint state_in)
{
    uint state = state_in * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
    return (word >> 22) ^ word;
}

float rand_unit(uint seed)
{
    return float(pcg_hash(seed)) * (1.0 / 4294967296.0);
}

// A random vector within a sphere of `radius`; each component from an independent hash.
float3 random_in_sphere(float radius, uint seed)
{
    float a = rand_unit(seed);
    float b = rand_unit(seed + 1);
    float c = rand_unit(seed + 2);
    float theta = a * 6.28318530718;
    float cos_phi = 2.0 * b - 1.0;
    float sin_phi = sqrt(max(0.0, 1.0 - cos_phi * cos_phi));
    float r = pow(c, 1.0 / 3.0) * radius;
    return float3(r * sin_phi * cos(theta), r * sin_phi * sin(theta), r * cos_phi);
}

// The placement whose range [emit_first, next placement's emit_first) holds new particle
// `id`: the last placement with emit_first <= id. Placements with no new particles share
// their successor's emit_first and are never picked.
uint find_placement(uint id)
{
    uint lo = 0;
    uint hi = params.emitter_placement_count;
    while (lo < hi) {
        uint mid = (lo + hi) / 2;
        if (placements[mid].emit_first <= id) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo - 1;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    uint id = gid.x;
    if (id >= params.emit_total) { return; }
    uint placement_index = find_placement(id);
    EmitterPlacement placed = placements[placement_index];
    Emitter emitter = emitters[placed.emitter];
    uint idx = (params.emit_cursor + id) % MAX_PARTICLES;
    // varies across frames, placements and particles: without frame_counter low-rate emitters
    // would spawn at the same point every frame
    uint seed = pcg_hash(idx
        ^ (params.frame_counter * 2654435761u)
        ^ (placement_index * 374761393u)
        ^ ((id - placed.emit_first) * 2246822519u));
    float4x4 world = nodes[placed.node].world_matrix;
    float3x3 rotation = mat3_of(world);
    float3 translation = float3(world[0][3], world[1][3], world[2][3]);
    // emitter position + random spread (local spread rotated into world space)
    float3 position = translation + mul(rotation, random_in_sphere(emitter.position_spread, seed));
    // initial_velocity + random spread, in local space
    // by component: naga's Metal output cannot add a packed struct vec3 to a vector
    float3 initial = float3(emitter.initial_velocity.x, emitter.initial_velocity.y, emitter.initial_velocity.z);
    float3 velocity = mul(rotation, initial + random_in_sphere(emitter.velocity_spread, seed + 7));
    float lifetime = emitter.particle_lifetime;
    float weight = emitter.weight + (rand_unit(seed + 13) - 0.5) * emitter.weight_spread;
    Particle p;
    p.position = position;
    p.size_start = emitter.size_start;
    p.velocity = velocity;
    p.size_end = emitter.size_end;
    p.color_start = emitter.color_start;
    p.color_end = emitter.color_end;
    p.life = lifetime;
    p.max_life = lifetime;
    p.weight = weight;
    p.texture_index = emitter.texture;
    particles[idx] = p;
}
