// Steers each fish by its neighbours (separation, alignment, cohesion), the food and the shark,
// reading one half of the fish buffer and writing the other, and counts what it moved into the
// indirect draw and the stats.
struct Params {
    uint count;
    uint src;
    float dt;
    uint vertices;
    float4 food;
    float4 predator;
    float4 weights;
    float4 tank_min;
    float4 tank_max;
}
#include "gpu.slang"

struct Fish {
    float3 position;
    float phase;
    float3 velocity;
    float size;
}

struct Counters {
    uint vertex_count;
    Atomic<uint> instance_count;
    uint first_vertex;
    uint first_instance;
    Atomic<uint> feeding;
    Atomic<uint> speed_milli;
}

[vk::binding(0, 1)] RWStructuredBuffer<Fish> fish;
[vk::binding(1, 1)] RWStructuredBuffer<Counters> counters;

static const uint MAX_FISH = 4096;
static const float VIEW_RADIUS = 2.5;
static const float SEPARATION_RADIUS = 0.8;

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint i = id.x;
    if (i == 0) counters[0].vertex_count = gpu.params.vertices;
    if (i >= gpu.params.count) return;
    uint base = gpu.params.src * MAX_FISH;
    Fish me = fish[base + i];
    float3 separate = float3(0.0);
    float3 heading = float3(0.0);
    float3 center = float3(0.0);
    float neighbours = 0.0;
    for (uint j = 0; j < gpu.params.count; j++) {
        if (j == i) continue;
        Fish other = fish[base + j];
        float3 offset = me.position - other.position;
        float d = length(offset);
        if (d > VIEW_RADIUS) continue;
        if (d < SEPARATION_RADIUS) separate += offset / max(d * d, 0.01);
        heading += other.velocity;
        center += other.position;
        neighbours += 1.0;
    }
    float4 w = gpu.params.weights;
    float3 steer = separate * w.x;
    if (neighbours > 0.0) {
        steer += (heading / neighbours - me.velocity) * w.y;
        steer += (center / neighbours - me.position) * w.z;
    }
    if (gpu.params.food.w > 0.0) steer += normalize(gpu.params.food.xyz - me.position) * 3.0;
    float3 away = me.position - gpu.params.predator.xyz;
    float danger = length(away);
    if (gpu.params.predator.w > 0.0 && danger < 4.0) steer += away / max(danger, 0.1) * (4.0 - danger) * 4.0;
    float3 lo = gpu.params.tank_min.xyz;
    float3 hi = gpu.params.tank_max.xyz;
    steer += (max(lo + 1.0 - me.position, 0.0) - max(me.position - hi + 1.0, 0.0)) * 4.0;

    float3 v = me.velocity + steer * gpu.params.dt;
    float speed = clamp(length(v), w.w * 0.3, w.w);
    v = normalize(v + float3(0.0, 0.0, 1e-4)) * speed;
    me.velocity = v;
    me.position = clamp(me.position + v * gpu.params.dt, lo, hi);
    me.phase = fmod(me.phase + gpu.params.dt * (4.0 + speed * 3.0), 6.2831853);
    fish[(1 - gpu.params.src) * MAX_FISH + i] = me;

    counters[0].instance_count.add(1);
    counters[0].speed_milli.add(uint(speed * 1000.0));
    if (gpu.params.food.w > 0.0 && distance(me.position, gpu.params.food.xyz) < 2.5) counters[0].feeding.add(1);
}
