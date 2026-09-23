#version 450
#extension GL_GOOGLE_include_directive : require
#include "convoyDust.glsl"
#include "sprite.glsl"
// Endless Convoy's dust: grit thrown past the wheels, a sprite per mote.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in float aSpeed;
layout(location = 0) out float vLife;
layout(location = 1) out vec2 vPointCoord;

void main() {
  vec3 pos = aPosition;
  // The grit is what actually travels. Wrapped through a forty-four unit band so the
  // road keeps arriving without anything ever being created or destroyed.
  float travel = uTime * (2.0 + aSpeed * 4.0);
  pos.x = mod(pos.x - travel + 22.0, 44.0) - 22.0;
  pos.y += sin(pos.x * 1.7 + aSpeed * 12.0) * 0.12;
  vLife = 0.25 + uHigh * 0.75;
  // Framebuffer pixels in both languages, and deliberately not scaled by the backing
  // ratio: the web asks for the same one-to-four-and-a-half pixel speck on every screen.
  float size = 1.0 + uHigh * 3.5;
  gl_Position = spriteCorner(projectionMatrix * modelViewMatrix * vec4(pos, 1.0), size, vPointCoord);
}
