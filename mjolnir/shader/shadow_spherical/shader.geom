#version 450
#extension GL_EXT_geometry_shader : enable

layout(triangles) in;
layout(triangle_strip, max_vertices = 18) out; // 3 vertices * 6 faces = 18

layout(location = 0) in vec3 worldPos[];
layout(location = 1) in uint instanceIndex[];

layout(location = 0) out vec3 fragWorldPos;

struct SphericalCamera {
    mat4 projection;
    vec4 position; // center.xyz, radius in w
    vec2 near_far;
    vec2 _padding;
};

layout(set = 0, binding = 0) readonly buffer SphericalCameraBuffer {
    SphericalCamera cameras[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

mat4 makeView(vec3 pos, vec3 forward, vec3 up)
{
    vec3 f = normalize(forward);
    vec3 r = normalize(cross(up, f));
    vec3 u = cross(f, r);

    mat4 m = mat4(
        vec4(r, 0.0),
        vec4(u, 0.0),
        vec4(f, 0.0),
        vec4(0.0, 0.0, 0.0, 1.0)
    );
    // convert to view matrix: R^T * T
    m = transpose(m);
    m[3].xyz = - (m[0].xyz * pos.x + m[1].xyz * pos.y + m[2].xyz * pos.z);
    return m;
}

void main() {
    SphericalCamera camera = cameras[camera_index];
    vec3 center = camera.position.xyz;

    mat4 views[6];
    // (+X, -X, +Y, -Y, +Z, -Z)
    views[0] = makeView(center, vec3(1,0,0),  vec3(0,-1,0));
    views[1] = makeView(center, vec3(-1,0,0), vec3(0,-1,0));
    views[2] = makeView(center, vec3(0,1,0),  vec3(0,0,1));
    views[3] = makeView(center, vec3(0,-1,0), vec3(0,0,-1));
    views[4] = makeView(center, vec3(0,0,1),  vec3(0,-1,0));
    views[5] = makeView(center, vec3(0,0,-1), vec3(0,-1,0));

    for (int face = 0; face < 6; face++) {
        gl_Layer = face;
        for (int i = 0; i < 3; i++) {
            fragWorldPos = worldPos[i];
            gl_Position = camera.projection * views[face] * vec4(worldPos[i], 1.0);
            EmitVertex();
        }
        EndPrimitive();
    }
}
