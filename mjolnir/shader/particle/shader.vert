#version 450

layout (location = 0) in vec4 inPosition;
// layout (location = 1) in vec4 inVelocity;
// layout (location = 2) in vec4 inColorStart;
// layout (location = 3) in vec4 inColorEnd;
layout (location = 4) in vec4 inColor;
layout (location = 5) in float inSize;
// layout (location = 6) in float inLife;
// layout (location = 7) in float inMaxLife;
// layout (location = 8) in uint inIsDead;

layout (location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstants {
    mat4 view;
    mat4 proj;
    float time;
};

out gl_PerVertex {
    vec4 gl_Position;
    float gl_PointSize;
};

void main() {
    vec4 cameraPosition = -inverse(view)[3];
    outColor = inColor;
    gl_Position = proj * view * inPosition;
    float dist = clamp(length((cameraPosition - inPosition).xyz), 1.0, 20.0);
    gl_PointSize = clamp(inSize / dist, 10.0, 100.0);
    // gl_PointSize = 50.0;
}
