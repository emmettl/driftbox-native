// What both of Machine's solid stages read: the camera and the three lights. `uLampRange` is
// ahead of the colours, where Metal had it last, since a scalar straight after a vec3 has no
// Swift layout.
layout(set = 0, binding = 0, std140) uniform MachineSolidUniforms {
  mat4 projectionMatrix;
  mat4 modelViewMatrix;
  float uLampRange;
  vec3 uEye;
  vec3 uAmbient;
  vec3 uSun;
  vec3 uSunDirection;
  vec3 uLamp;
  vec3 uLampPosition;
  vec3 uGlow;
};
