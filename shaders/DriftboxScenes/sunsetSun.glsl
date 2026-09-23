// What both of Sunset's sun stages read.
layout(set = 0, binding = 0, std140) uniform SunsetSunUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uBass;
  vec3 uTop;
  vec3 uBottom;
};
