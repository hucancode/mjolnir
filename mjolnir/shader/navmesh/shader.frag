#version 450

layout(location = 0) in vec4 inColor;
layout(location = 1) in flat uint inColorMode;
layout(location = 0) out vec4 outColor;

// Simple hash function to generate pseudo-random colors
vec3 hash31(uint n) {
    n = (n << 13U) ^ n;
    n = n * (n * n * 15731U + 789221U) + 1376312589U;
    uint k = n * 3U;
    vec3 res;
    res.x = float((k >> 0) & 0xFFFFFFU) / float(0xFFFFFF);
    res.y = float((k >> 8) & 0xFFFFFFU) / float(0xFFFFFF);
    res.z = float((k >> 16) & 0xFFFFFFU) / float(0xFFFFFF);
    return res;
}

// Convert HSV to RGB
vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    vec3 finalColor = inColor.rgb;
    
    // Color mode: 0=area colors, 1=uniform, 2=height based, 3=random colors
    if (inColorMode == 3) {
        // Random colors mode - use gl_PrimitiveID to generate unique color per triangle
        uint primitiveId = uint(gl_PrimitiveID);
        
        // Generate a hash-based color with good distribution
        vec3 hashColor = hash31(primitiveId * 137U);
        
        // Convert to HSV for better color distribution
        // Use hash for hue, high saturation, good brightness
        vec3 hsv = vec3(hashColor.x, 0.8 + hashColor.y * 0.2, 0.6 + hashColor.z * 0.4);
        finalColor = hsv2rgb(hsv);
    }
    
    outColor = vec4(finalColor, inColor.a);
}
