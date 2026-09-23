// What both of Cycles' wall stages read. The colour comes last, not first as Metal had it: a
// scalar straight after a vec3 is a layout Swift cannot match.
layout(set = 0, binding = 0, std140) uniform CyclesWallUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uTime;
  float uBass;
  float uDerez;
  vec3 uColour;
};
