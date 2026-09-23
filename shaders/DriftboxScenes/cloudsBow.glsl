// What both of the Clouds rainbow's stages read.
layout(set = 0, binding = 0, std140) uniform CloudsBowUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uShow;
};
