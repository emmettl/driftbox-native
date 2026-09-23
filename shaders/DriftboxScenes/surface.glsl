// What every surface scene's shaders share: the uniforms, under the names the web's scenes give them
// so that a scene reads as its GLSL there does, and the helpers every scene draws with.
//
// The hits are vec4s, of which only x (when) and y (how hard) are read: std140 puts the elements of
// any array sixteen bytes apart, and a Swift array of pairs cannot be laid out to match.
layout(set = 0, binding = 0, std140) uniform SurfaceUniforms {
  vec2 uSize;
  float uTime;
  float uTravel;
  float uBeat;
  float uScoreBeat;
  float uBass;
  float uMid;
  float uHigh;
  vec3 uTouch;
  vec4 uHits[8];
};

#include "common.glsl"

// A card: one of an instanced layer of quads, the web's planeGeometry(2, 2).
const vec2 cardCorners[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, -1), vec2(1, 1), vec2(-1, 1));
