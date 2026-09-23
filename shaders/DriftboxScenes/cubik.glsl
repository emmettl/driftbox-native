// What both of Cubik's stages read.
layout(set = 0, binding = 0, std140) uniform CubikUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  mat4 normalMatrix;
  // One per band, in .x: std140 spaces a float array's elements sixteen bytes apart anyway, and
  // Swift can only match that as an array of vec4.
  vec4 uBands[12];
  float uTime;
  float uBass;
  float uHigh;
  float uWarp;
  vec2 uTouch;
};
