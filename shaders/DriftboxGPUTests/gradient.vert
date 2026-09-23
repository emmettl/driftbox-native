#version 450
// Three vertices that cover the screen, and where each fragment is on it: 0...1 from the bottom left.
layout(location = 0) out vec2 vUv;

void main() {
  vec2 corners[3] = vec2[](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
  vUv = (corners[gl_VertexIndex] + 1.0) * 0.5;
  gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
}
