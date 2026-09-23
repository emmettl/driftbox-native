#version 450
#extension GL_GOOGLE_include_directive : require
#include "lifeforms.glsl"
// Lifeforms: a sphere pushed in and out by layered noise so the silhouette never repeats,
// inflated by the bass, shivering on the highs, dragged toward a finger.
layout(location = 0) in vec3 aPosition;
layout(location = 0) out vec3 vNormal;
layout(location = 1) out vec3 vView;
layout(location = 2) out float vBulge;

// Cheap 3D value noise. Not the good kind, but this runs per vertex per frame, and the
// difference is invisible once three octaves are layered and the whole thing is moving.
vec3 lifeformsHash3(vec3 p) {
  p = vec3(dot(p, vec3(127.1, 311.7, 74.7)),
           dot(p, vec3(269.5, 183.3, 246.1)),
           dot(p, vec3(113.5, 271.9, 124.6)));
  return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float lifeformsNoise(vec3 p) {
  vec3 i = floor(p);
  vec3 f = fract(p);
  vec3 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(dot(lifeformsHash3(i + vec3(0,0,0)), f - vec3(0,0,0)),
            dot(lifeformsHash3(i + vec3(1,0,0)), f - vec3(1,0,0)), u.x),
        mix(dot(lifeformsHash3(i + vec3(0,1,0)), f - vec3(0,1,0)),
            dot(lifeformsHash3(i + vec3(1,1,0)), f - vec3(1,1,0)), u.x), u.y),
    mix(mix(dot(lifeformsHash3(i + vec3(0,0,1)), f - vec3(0,0,1)),
            dot(lifeformsHash3(i + vec3(1,0,1)), f - vec3(1,0,1)), u.x),
        mix(dot(lifeformsHash3(i + vec3(0,1,1)), f - vec3(0,1,1)),
            dot(lifeformsHash3(i + vec3(1,1,1)), f - vec3(1,1,1)), u.x), u.y), u.z);
}

void main() {
  vec3 pos = aPosition;
  vec3 n = normalize(pos);
  // Three octaves, each drifting at its own speed so the surface never repeats.
  float slow = lifeformsNoise(n * 1.4 + vec3(uSeed, uTime * 0.13, 0.0));
  float mid = lifeformsNoise(n * 3.1 + vec3(0.0, uTime * 0.29, uSeed)) * 0.45;
  float fast = lifeformsNoise(n * 7.4 + vec3(uTime * 0.6, uSeed, 0.0)) * 0.18;
  // Bass inflates the whole body; highs only reach the fine octave, so hats read as a
  // shiver across the surface rather than as the thing breathing faster.
  float bulge = slow * (0.34 + uBass * 0.72) + mid * (0.2 + uHigh * 0.5) + fast * uHigh * 1.4;
  pos += n * bulge;
  // Dragged toward the finger, and squashed along the way — a body leaning, not a whole
  // object sliding.
  vec3 toPull = uPull - pos;
  pos += toPull * uWarp * 0.85 * (0.4 + slow * 0.6);
  pos -= n * dot(n, normalize(toPull + vec3(0.0001))) * uWarp * 0.3;
  vBulge = bulge;
  vNormal = normalize((normalMatrix * vec4(n, 0.0)).xyz);
  vec4 mv = modelViewMatrix * vec4(pos, 1.0);
  vView = -mv.xyz;
  gl_Position = projectionMatrix * mv;
}
