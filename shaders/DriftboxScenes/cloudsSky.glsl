// What both of the Clouds sky's stages read. The sun comes after the bass, not before it as Metal
// had them: a scalar straight after a vec3 is a layout Swift cannot match.
layout(set = 0, binding = 0, std140) uniform CloudsSkyUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uBass;
  vec3 uSun;
};
