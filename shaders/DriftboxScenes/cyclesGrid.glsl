// What the grid's stages read, and the riders' vertex stage: Metal bound the grid's uniforms to
// both pipelines.
layout(set = 0, binding = 0, std140) uniform CyclesGridUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uBass;
  float uDerez;
  float uPixel;
};
