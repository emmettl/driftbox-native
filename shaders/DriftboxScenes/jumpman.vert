#version 450
#extension GL_GOOGLE_include_directive : require
#include "jumpman.glsl"
#include "sprite.glsl"
// Jump Man: every cell of every sprite on screen is a block in space, one sprite per cell,
// refilled from scratch every frame.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aColour;
layout(location = 2) in float aSize;
layout(location = 3) in float aGlow;
layout(location = 0) out vec3 vColour;
layout(location = 1) out float vGlow;
layout(location = 2) out vec2 vPointCoord;

void main() {
  vColour = aColour;
  vGlow = aGlow;
  vec4 view = modelViewMatrix * vec4(aPosition, 1.0);
  float size = aSize * uPixelRatio * (520.0 / max(1.0, -view.z));
  gl_Position = spriteCorner(projectionMatrix * view, size, vPointCoord);
}
