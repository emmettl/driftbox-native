// What both of the Dancers' figure stages read.
layout(set = 0, binding = 0, std140) uniform DancersFigureUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uBass;
};
