#version 450
layout(location = 0) in vec4 inPosition;
layout(set = 0, binding = 0) uniform LightMatrix {
    mat4 lightViewProj;
};
layout(push_constant) uniform Constants {
    mat4 world;
};
void main() {
    gl_Position = lightViewProj * world * inPosition;
}
