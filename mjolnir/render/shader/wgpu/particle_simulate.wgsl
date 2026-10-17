// Advances every live particle and appends it to the alive list, whose header is the indirect
// draw: the instance count (word 1) grows with one atomic per group; the vertex count stays six.

const MAX_PARTICLES: u32 = 65536u;
const MAX_FORCE_FIELDS: u32 = 32u;
const GRAVITY: vec3f = vec3f(0.0, -9.8, 0.0);

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

struct ForceField {
    tangent_strength: f32,
    strength: f32,
    area_of_effect: f32,
}

struct ForceFieldPlacement {
    forcefield: u32,
    node: u32,
}

// the indirect draw (vertex count, instance count, first vertex, first instance), then the
// alive particles' indices
struct Alive {
    header: array<atomic<u32>, 4>,
    alive: array<u32>,
}

@group(0) @binding(0) var<storage, read> nodes: array<Node>;
@group(0) @binding(1) var<storage, read> forcefields: array<ForceField>;
@group(0) @binding(2) var<storage, read_write> particles: array<Particle>;
@group(0) @binding(3) var<storage, read_write> alive: Alive;
@group(0) @binding(4) var<storage, read> placements: array<ForceFieldPlacement>;

struct ParticleSystemParams {
    emitter_placement_count: u32,
    forcefield_placement_count: u32,
    delta_time: f32,
    frame_counter: u32,
    emit_total: u32,
    emit_cursor: u32,
}
@group(2) @binding(0) var<uniform> u: ParticleSystemParams;

// Advance live particle i; returns whether it is still alive.
fn simulate(i: u32) -> bool {
    let p = particles[i].position;
    var v = particles[i].velocity;
    let n = min(u.forcefield_placement_count, MAX_FORCE_FIELDS);
    for (var f = 0u; f < n; f++) {
        let placed = placements[f];
        // free rows and destroyed force fields are zero: area_of_effect 0
        let ff = forcefields[placed.forcefield];
        if (ff.area_of_effect <= 0.0 || placed.node == 0u) { continue; }
        let ff_pos = nodes[placed.node].world_matrix[3].xyz;
        let dist = length(p - ff_pos);
        if (dist > ff.area_of_effect) { continue; }
        let effect = 1.0 - clamp(dist / ff.area_of_effect, 0.0, 1.0);
        let dir = (ff_pos - p) / max(dist, 1e-4);
        let reference = mix(vec3f(0.0, 1.0, 0.0), vec3f(1.0, 0.0, 0.0), step(0.99, abs(dir.y)));
        let tangent = normalize(cross(reference, dir));
        let force = dir * ff.strength + tangent * ff.tangent_strength;
        v += force * effect * u.delta_time;
    }
    v += GRAVITY * particles[i].weight * u.delta_time;
    // limit speed (branchless div-by-zero guard)
    let speed = length(v);
    v *= min(speed, 5.0) / max(speed, 1e-6);
    particles[i].velocity = v;
    particles[i].position = p + v * u.delta_time;
    let life = particles[i].life - u.delta_time;
    particles[i].life = life;
    return life > 0.0;
}

// live particles of this group, appended to the alive list with one global atomic per group
var<workgroup> group_alive: atomic<u32>;
var<workgroup> group_first: u32;

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3u, @builtin(local_invocation_index) local: u32) {
    let i = gid.x;
    if (local == 0u) {
        atomicStore(&group_alive, 0u);
    }
    workgroupBarrier();
    var live = i < MAX_PARTICLES && particles[i].life > 0.0;
    var slot = 0u;
    if (live) {
        live = simulate(i);
        if (live) {
            slot = atomicAdd(&group_alive, 1u);
        }
    }
    workgroupBarrier();
    if (local == 0u) {
        group_first = atomicAdd(&alive.header[1], atomicLoad(&group_alive));
    }
    workgroupBarrier();
    if (live) {
        alive.alive[group_first + slot] = i;
    }
}
