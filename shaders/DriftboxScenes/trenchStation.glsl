// What both of Trench's station stages read.
layout(set = 0, binding = 0, std140) uniform TrenchStationUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  vec2 uTouch;
  // Where the fog starts and ends, in world units.
  vec2 uFog;
  float uBass;
  float uHigh;
  float uWarp;
};
