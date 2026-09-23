// What every surface scene's shaders share: the uniforms, under the names the web's scenes give them
// so that a scene reads as its GLSL there does, and the helpers they draw with.
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

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float line(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a, ba = b - a;
  return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

mat2 rotation(float c, float s) { return mat2(vec2(c, -s), vec2(s, c)); }

// A card: one of an instanced layer of quads, the web's planeGeometry(2, 2).
const vec2 cardCorners[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, -1), vec2(1, 1), vec2(-1, 1));
