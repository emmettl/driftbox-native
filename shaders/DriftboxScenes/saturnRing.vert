#version 450
#extension GL_GOOGLE_include_directive : require
#include "saturnRing.glsl"
#include "sprite.glsl"
// Saturn's rings: particles on Keplerian orbits, shimmering on the sixteenths.
layout(location = 0) in float aRadius;
layout(location = 1) in float aPhase;
layout(location = 2) in float aGrit;
layout(location = 0) out float vShine;
layout(location = 1) out float vRadius;
layout(location = 2) out vec2 vPointCoord;

const float RING_INNER = 12.0;
const float RING_WIDTH = 10.0;

void main() {
  // Keplerian: the inner ring goes round faster than the outer one. This is the single
  // thing that stops the rings looking like a painted disc.
  float speed = 26.0 / pow(aRadius, 1.5);
  float angle = aPhase + uTime * speed;
  float r = aRadius * (1.0 + uBass * 0.012);
  // The sixteenths make the ring particles jitter in and out. A break this busy needs
  // somewhere to go that is not brightness.
  r += sin(aPhase * 40.0 + uTime * 9.0) * uHat * 0.5 * aGrit;
  // A finger fans the rings out and thickens them.
  r += uWarp * aGrit * 1.6;
  vec3 pos = vec3(cos(angle) * r, aGrit * 0.18 * (1.0 + uHat * 2.0 + uWarp * 6.0), sin(angle) * r);
  vShine = 0.35 + uHat * 0.9;
  vRadius = (aRadius - RING_INNER) / RING_WIDTH;
  vec4 view = modelViewMatrix * vec4(pos, 1.0);
  float size = clamp(90.0 / -view.z, 1.0, 2.6) * uPixelRatio;
  gl_Position = spriteCorner(projectionMatrix * view, size, vPointCoord);
}
