#version 450
#extension GL_GOOGLE_include_directive : require
#include "saturnPlanet.glsl"
#include "sprite.glsl"
// Saturn's planet: a point cloud on a Fibonacci sphere, punched by the big hits — a white flash,
// then a dark scar that outlives it by a long way.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out vec3 vNormal;
layout(location = 1) out float vFlash;
layout(location = 2) out float vScar;
layout(location = 3) out vec2 vPointCoord;

void main() {
  vec3 dir = normalize(aPosition);
  float lift = 0.0, flash = 0.0, scar = 0.0;
  for (int i = 0; i < 10; i++) {
    vec4 hit = uImpacts[i];
    if (hit.w < 0.0) continue;
    // Angular distance from the impact point: cheaper than acos and monotonic in it,
    // which is all this needs — the falloff constants are tuned against it.
    float sep = 1.0 - dot(dir, normalize(hit.xyz));
    float age = hit.w;
    // The flash: bright, brief, and spreading outward as a shock front for the first
    // moments so it reads as something arriving rather than a lamp switching on.
    float front = 0.02 + age * 0.35;
    flash += exp(-(sep - front) * (sep - front) * 900.0) * exp(-age * 5.0);
    // The scar: a fixed blot that decays over many seconds.
    float blot = exp(-sep * sep * 260.0);
    scar += blot * exp(-age * 0.18);
    // And the surface itself is thrown up a little where it was hit.
    lift += blot * exp(-age * 1.2) * 0.5;
  }
  vec3 pos = aPosition * (1.0 + uBass * 0.02 + lift * 0.06);
  vNormal = dir;
  vFlash = flash;
  vScar = min(scar, 1.0);
  vec4 view = modelViewMatrix * vec4(pos, 1.0);
  float size = clamp(140.0 / -view.z, 1.0, 3.4) * uPixelRatio;
  gl_Position = spriteCorner(projectionMatrix * view, size, vPointCoord);
}
