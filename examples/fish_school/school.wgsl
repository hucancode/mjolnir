// Steers each fish by its neighbours (separation, alignment, cohesion), the food and the shark,
// reading one half of the fish buffer and writing the other, and counts what it moved into the
// indirect draw and the stats.

struct Params {
    count: u32,
    src: u32,
    dt: f32,
    vertices: u32,
    food: vec4f,
    predator: vec4f,
    weights: vec4f,
    tank_min: vec4f,
    tank_max: vec4f,
}

struct Fish {
    position: vec3f,
    phase: f32,
    velocity: vec3f,
    size: f32,
}

struct Counters {
    vertex_count: u32,
    instance_count: atomic<u32>,
    first_vertex: u32,
    first_instance: u32,
    feeding: atomic<u32>,
    speed_milli: atomic<u32>,
}

@group(1) @binding(0) var<storage, read_write> fish: array<Fish>;
@group(1) @binding(1) var<storage, read_write> counters: Counters;

const MAX_FISH: u32 = 4096u;
const VIEW_RADIUS: f32 = 2.5;
const SEPARATION_RADIUS: f32 = 0.8;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let i = id.x;
    let p = gpu.params;
    if (i == 0u) {
        counters.vertex_count = p.vertices;
    }
    if (i >= p.count) {
        return;
    }
    let base = p.src * MAX_FISH;
    var me = fish[base + i];
    var separate = vec3f(0.0);
    var heading = vec3f(0.0);
    var center = vec3f(0.0);
    var neighbours = 0.0;
    for (var j = 0u; j < p.count; j++) {
        if (j == i) {
            continue;
        }
        let other = fish[base + j];
        let offset = me.position - other.position;
        let d = length(offset);
        if (d > VIEW_RADIUS) {
            continue;
        }
        if (d < SEPARATION_RADIUS) {
            separate += offset / max(d * d, 0.01);
        }
        heading += other.velocity;
        center += other.position;
        neighbours += 1.0;
    }
    let w = p.weights;
    var steer = separate * w.x;
    if (neighbours > 0.0) {
        steer += (heading / neighbours - me.velocity) * w.y;
        steer += (center / neighbours - me.position) * w.z;
    }
    if (p.food.w > 0.0) {
        steer += normalize(p.food.xyz - me.position) * 3.0;
    }
    let away = me.position - p.predator.xyz;
    let danger = length(away);
    if (p.predator.w > 0.0 && danger < 4.0) {
        steer += away / max(danger, 0.1) * (4.0 - danger) * 4.0;
    }
    let lo = p.tank_min.xyz;
    let hi = p.tank_max.xyz;
    steer += (max(lo + 1.0 - me.position, vec3f(0.0)) - max(me.position - hi + 1.0, vec3f(0.0))) * 4.0;

    let v = me.velocity + steer * p.dt;
    let speed = clamp(length(v), w.w * 0.3, w.w);
    me.velocity = normalize(v + vec3f(0.0, 0.0, 1e-4)) * speed;
    me.position = clamp(me.position + me.velocity * p.dt, lo, hi);
    me.phase = (me.phase + p.dt * (4.0 + speed * 3.0)) % 6.2831853;
    fish[(1u - p.src) * MAX_FISH + i] = me;

    atomicAdd(&counters.instance_count, 1u);
    atomicAdd(&counters.speed_milli, u32(speed * 1000.0));
    if (p.food.w > 0.0 && distance(me.position, p.food.xyz) < 2.5) {
        atomicAdd(&counters.feeding, 1u);
    }
}
