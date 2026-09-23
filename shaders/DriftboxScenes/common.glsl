// The helpers every scene's shaders may draw with, as the Metal scenes had them in the surface
// scenes' preamble, which the geometry scenes were compiled after. GLSL's own `mod` is the floored
// one that preamble defined, so it needs no helper here.
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float line(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a, ba = b - a;
  return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

mat2 rotation(float c, float s) { return mat2(vec2(c, -s), vec2(s, c)); }
