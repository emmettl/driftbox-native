// What both of the Clouds puffs' stages read.
layout(set = 0, binding = 0, std140) uniform CloudsPuffUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  // Each cloud's placement and squash, (x, y, z, squash): a small table of per-cloud state
  // updated each frame, which Metal handed over as a buffer of its own. Room for Clouds.clouds.
  vec4 uClouds[7];
  float uPixelRatio;
};
