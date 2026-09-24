#version 450
// A page drawn over a finished frame, whole: a quad covering the target, drawn as a strip of four,
// sampling with the texture's own origin at the top, as `present` does.
layout(location = 0) out vec2 vUv;

void main() {
  vec2 corners[4] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0));
  vec2 corner = corners[gl_VertexIndex];
  vUv = vec2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
  gl_Position = vec4(corner, 0.0, 1.0);
}
