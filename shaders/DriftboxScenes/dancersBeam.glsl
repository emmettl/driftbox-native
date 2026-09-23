// What both of the Dancers' beam stages read.
layout(set = 0, binding = 0, std140) uniform DancersBeamUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uHigh;
};
