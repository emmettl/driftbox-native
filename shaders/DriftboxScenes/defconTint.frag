#version 450
#extension GL_GOOGLE_include_directive : require
#include "defconTint.glsl"
layout(location = 0) in vec3 vColour;
layout(location = 0) out vec4 fragColor;

// And the same material with `vertexColors` on. The trails carry brightness well past one,
// as they do on the web: the target clamps it on the way out rather than the shader.
void main() {
  fragColor = vec4(vColour, uOpacity);
}
