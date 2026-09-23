#version 450
// A finished frame shown in a view: a quad scaled to the fitted rectangle, drawn as a strip of
// four, sampling with the texture's own origin at the top, which is where a pass put row zero.
layout(set = 0, binding = 0, std140) uniform PresentUniforms {
  vec2 scale;
} u;
layout(location = 0) out vec2 vUv;

void main() {
  vec2 corners[4] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0));
  vec2 corner = corners[gl_VertexIndex];
  vUv = vec2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
  gl_Position = vec4(corner * u.scale, 0.0, 1.0);
}
