// What both of the Convoy dust's stages read.
layout(set = 0, binding = 0, std140) uniform ConvoyDustUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uHigh;
};
