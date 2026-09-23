#version 450
// A block with every kind of member the scenes' blocks have, for the layout test to hold Swift to.
layout(set = 0, binding = 0, std140) uniform LayoutUniforms {
  mat4 projection;
  vec2 size;
  float time;
  float scale;
  vec4 hits[4];
  float bass;
  vec2 touch;
  vec3 accent;
} u;

void main() {
  gl_Position = u.projection * vec4(u.size, u.time + u.scale + u.bass, 1.0) + u.hits[3] + vec4(u.touch, u.accent.xy);
}
