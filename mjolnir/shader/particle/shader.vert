#version 450

layout (location = 0) in vec4 inPosition;
layout (location = 1) in vec4 inColor;
layout (location = 2) in float inSize;
layout (location = 3) in uint inTextureIndex;

layout (location = 0) out vec4 outColor;
layout (location = 1) out flat uint outTextureIndex;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_PointSize;
};

// camera set = 0
layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
};

void main() {
    vec4 cameraPosition = -inverse(view)[3];
    outColor = inColor;
    outTextureIndex = inTextureIndex;
    gl_Position = proj * view * inPosition;
    float dist = clamp(length((cameraPosition - inPosition).xyz), 1.0, 20.0);
    gl_PointSize = clamp(inSize / dist, 10.0, 100.0);
}
