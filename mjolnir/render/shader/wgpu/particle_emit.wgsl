// Spawns the frame's new particles: one thread per new particle, written to the ring slot
// after the previous one; once the ring is full new particles overwrite the oldest.

const MAX_PARTICLES: u32 = 65536u;

struct Particle {
    position: vec3f,
    size_start: f32,
    velocity: vec3f,
    size_end: f32,
    color_start: vec4f,
    color_end: vec4f,
    life: f32,
    max_life: f32,
    weight: f32,
    texture_index: u32,
}

struct Emitter {
    initial_velocity: vec3f,
    size_start: f32,
    color_start: vec4f,
    color_end: vec4f,
    particle_lifetime: f32,
    position_spread: f32,
    velocity_spread: f32,
    emit_first: u32,
    size_end: f32,
    weight: f32,
    weight_spread: f32,
    texture_index: u32,
    node_index: u32,
    // CPU side only
    emission_rate: f32,
    enabled: u32,
    _pad0: u32,
}

@group(0) @binding(0) var<storage, read> nodes: array<Node>;
@group(0) @binding(1) var<storage, read> emitters: array<Emitter>;
@group(0) @binding(2) var<storage, read_write> particles: array<Particle>;

struct Params {
    emitter_count: u32,
    forcefield_count: u32,
    delta_time: f32,
    frame_counter: u32,
    // new particles this frame
    emit_total: u32,
    // ring slot of the first one
    emit_cursor: u32,
}
@group(2) @binding(0) var<uniform> u: Params;

// PCG hash: independent, well-distributed 32-bit outputs even when inputs differ by 1, so
// spawn positions do not cluster when the emitter index dominates the seed.
fn pcg_hash(state_in: u32) -> u32 {
    let state = state_in * 747796405u + 2891336453u;
    let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

fn rand_unit(seed: u32) -> f32 {
    return f32(pcg_hash(seed)) * (1.0 / 4294967296.0);
}

// A random vector within a sphere of `radius`; each component from an independent hash.
fn random_in_sphere(radius: f32, seed: u32) -> vec3f {
    let a = rand_unit(seed);
    let b = rand_unit(seed + 1u);
    let c = rand_unit(seed + 2u);
    let theta = a * 6.28318530718;
    let cos_phi = 2.0 * b - 1.0;
    let sin_phi = sqrt(max(0.0, 1.0 - cos_phi * cos_phi));
    let r = pow(c, 1.0 / 3.0) * radius;
    return vec3f(r * sin_phi * cos(theta), r * sin_phi * sin(theta), r * cos_phi);
}

// The emitter whose range [emit_first, next emitter's emit_first) holds new particle `id`:
// the last emitter with emit_first <= id. Emitters with no new particles share their
// successor's emit_first and are never picked.
fn find_emitter(id: u32) -> u32 {
    var lo = 0u;
    var hi = u.emitter_count;
    while (lo < hi) {
        let mid = (lo + hi) / 2u;
        if (emitters[mid].emit_first <= id) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    return lo - 1u;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    let id = gid.x;
    if (id >= u.emit_total) { return; }
    let emitter_index = find_emitter(id);
    let emitter = emitters[emitter_index];
    // unattached
    if (emitter.node_index == 0u) { return; }
    let idx = (u.emit_cursor + id) % MAX_PARTICLES;
    // varies across frames, emitters and particles: without frame_counter low-rate emitters
    // would spawn at the same point every frame
    let seed = pcg_hash(idx
        ^ (u.frame_counter * 2654435761u)
        ^ (emitter_index * 374761393u)
        ^ ((id - emitter.emit_first) * 2246822519u));
    let world = nodes[emitter.node_index].world_matrix;
    let rotation = mat3x3f(world[0].xyz, world[1].xyz, world[2].xyz);
    // emitter position + random spread (local spread rotated into world space)
    let position = world[3].xyz + rotation * random_in_sphere(emitter.position_spread, seed);
    // initial_velocity + random spread, in local space
    // by component: naga's Metal output cannot add a packed struct vec3 to a vector
    let initial = vec3f(emitter.initial_velocity.x, emitter.initial_velocity.y, emitter.initial_velocity.z);
    let velocity = rotation * (initial + random_in_sphere(emitter.velocity_spread, seed + 7u));
    let lifetime = emitter.particle_lifetime;
    let weight = emitter.weight + (rand_unit(seed + 13u) - 0.5) * emitter.weight_spread;
    particles[idx] = Particle(
        position,
        emitter.size_start,
        velocity,
        emitter.size_end,
        emitter.color_start,
        emitter.color_end,
        lifetime,
        lifetime,
        weight,
        emitter.texture_index,
    );
}
