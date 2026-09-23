// What Jump Man's vertex stage reads.
layout(set = 0, binding = 0, std140) uniform JumpmanUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uPixelRatio;
};
