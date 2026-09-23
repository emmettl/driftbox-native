// What both of Stillwater's haze stages read.
layout(set = 0, binding = 0, std140) uniform StillwaterHazeUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uBass;
};
