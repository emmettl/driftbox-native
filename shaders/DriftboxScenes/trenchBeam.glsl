// The whole of three's `LineBasicMaterial` as Trench's beams use it: a position, the vertex
// colour and an opacity. Its own diffuse is white and nothing multiplies it, so the strand
// colour written into the buffer is what comes out.
layout(set = 0, binding = 0, std140) uniform TrenchBeamUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uOpacity;
};
