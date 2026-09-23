// What both of the Convoy road's stages read.
layout(set = 0, binding = 0, std140) uniform ConvoyRoadUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uHigh;
};
