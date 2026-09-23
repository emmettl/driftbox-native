// What both of Defcon's vertex-coloured line stages read.
layout(set = 0, binding = 0, std140) uniform DefconTintUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uOpacity;
};
