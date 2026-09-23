#version 450
// Positions from a vertex buffer, moved by a matrix, in one colour.
layout(set = 0, binding = 0, std140) uniform FlatUniforms {
  mat4 transform;
  vec4 colour;
} u;
layout(location = 0) in vec3 aPosition;

void main() {
  gl_Position = u.transform * vec4(aPosition, 1.0);
}
