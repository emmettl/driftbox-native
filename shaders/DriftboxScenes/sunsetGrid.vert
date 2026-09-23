#version 450
#extension GL_GOOGLE_include_directive : require
#include "sunsetGrid.glsl"
// Sunset's wireframe floor, running to the horizon: rolling hills that swell with the bass, and a
// finger pulling the floor toward it so the grid lines stretch around the touch.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec2 aUv;
layout(location = 0) out vec2 vUv;
layout(location = 1) out float vPull;

void main() {
  vUv = aUv;
  vec3 pos = aPosition;
  // A slow swell in the floor, deeper when the low end is loud: rolling hills rather
  // than a flat plane, so the grid has something to describe.
  float ridge = sin(pos.x * 0.18 + uTime * 0.25) * cos(pos.y * 0.13 - uTime * 0.16);
  pos.z += ridge * (1.1 + uBass * 3.4) * smoothstep(4.0, 40.0, abs(pos.y));
  // The finger: a gaussian well centred on it, so the floor lifts toward the touch and
  // falls away smoothly rather than denting at a point. uSpread is the width of floor
  // the camera can actually see, and the depth range is tight for the same reason.
  vec2 target = vec2((uTouch.x - 0.5) * uSpread, mix(9.0, 40.0, 1.0 - uTouch.y));
  float d = length(pos.xy - target);
  // Two envelopes, not one, and this is the whole trick. A single gaussian forces a
  // choice: tight enough to keep the horizon, or wide enough to be obvious, never both.
  // So the LIFT stays tight and tall, and a separate, far wider envelope carries a
  // travelling ripple out across the rest of the floor.
  float pull = exp(-d * d / 520.0);
  pos.z += pull * uWarp * 58.0;
  // The wake stays SMALL even though it is wide: the floor sits about half a unit below
  // the camera, and a ripple as tall as the central lift stops reading as a floor at all.
  float wake = exp(-d * d / 5200.0);
  pos.z += sin(d * 0.26 - uTime * 6.0) * wake * uWarp * 4.5;
  // A second, slower wave the other way, so the interference never repeats.
  pos.z += sin(d * 0.11 + uTime * 2.3) * wake * uWarp * 2.2;
  // Lit by the spike AND the wake, so the glow spreads with the disturbance.
  vPull = (pull + wake * 0.55) * uWarp;
  // (The Metal shader also wrote a vDist, length(pos.xy), which its fragment never read.)
  gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
}
