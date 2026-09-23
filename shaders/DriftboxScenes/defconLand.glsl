// What both of Defcon's land stages read.
layout(set = 0, binding = 0, std140) uniform DefconLandUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uBass;
  float uAlert;
};
