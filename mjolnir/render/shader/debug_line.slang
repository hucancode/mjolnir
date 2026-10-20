// Debug lines pulled from the debug line table: vertex 2i is segment i's a end, 2i + 1 its b
// end. A segment past its expiry is moved outside the clip volume.
#include "common.slang"

struct DebugLineSegment {
    float3 a;
    // render clock time the segment stops drawing after
    float expiry;
    float3 b;
    uint _pad;
    float4 color;
}
SCENE_BUFFER(DebugLineSegment, segments, 12, 1)

struct DebugLinePush { uint camera_index; }
PUSH_BLOCK(DebugLinePush, push)

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float4 color : COLOR0;
}

[shader("vertex")]
VertexOut vs_main(uint i : VERTEX_ID)
{
    DebugLineSegment s = segments[i >> 1];
    VertexOut o;
    o.color = float4(0);
    if (s.expiry < views[push.camera_index].time) {
        o.clip = CLIP_DISCARD;
        return o;
    }
    float3 position = (i & 1) == 0 ? s.a : s.b;
    o.clip = clip_output(mul(views[push.camera_index].view_projection, float4(position, 1.0)));
    o.color = s.color;
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    return v.color;
}
