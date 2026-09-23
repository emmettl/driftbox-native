#version 450
#extension GL_GOOGLE_include_directive : require
#include "dancersFigure.glsl"
// The dancers: five lay figures of tapered prisms and ball joints, one line list rewritten every
// frame, each vertex carrying its dancer's colour and how hot the beat has made that limb.
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aColour;
layout(location = 2) in float aGlow;
layout(location = 0) out vec3 vColour;
layout(location = 1) out float vGlow;

void main() {
  vColour = aColour;
  vGlow = aGlow;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPosition, 1.0);
}
