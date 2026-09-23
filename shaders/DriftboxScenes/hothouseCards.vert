#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Hothouse's cards: instanced quads, each placed by its own matrix, which steps per instance.
layout(location = 0) in vec4 aInstance0;
layout(location = 1) in vec4 aInstance1;
layout(location = 2) in vec4 aInstance2;
layout(location = 3) in vec4 aInstance3;
layout(location = 0) out vec2 vUv;
layout(location = 1) out vec2 vPage;
layout(location = 2) out float vSeed;

// Shared by the stems and their leaves: the whole plant leans, with its root fixed.
vec2 hothouseSway(float n, float depth) {
  float side = mod(n,2.0)*2.0-1.0;
  float breeze = sin(uTravel*0.95+n*0.83)*(0.025+depth*0.055);
  float bassLean = side*uBass*(0.014+depth*0.035);
  float lift = sin(uTravel*0.72+n*0.61)*0.014*(0.3+depth)*(0.4+uMid);
  return vec2(breeze+bassLean,lift);
}
void main() {
  mat4 instanceMatrix=mat4(aInstance0,aInstance1,aInstance2,aInstance3);
  vec2 position=cardCorners[gl_VertexIndex];
  vUv = (position+1.0)*0.5;
  vSeed = instanceMatrix[3].z;
  vec4 p = instanceMatrix*vec4(position,0.0,1.0);
  float n = floor(vSeed), branch = floor(fract(vSeed)*10.0+0.5);
  float depth = floor(n/2.0)/6.0;
  float at = 0.42+branch*0.22;
  // Hinge at the leaf's attachment to the stem, rather than sliding the card loose.
  vec2 attachment = instanceMatrix[3].xy-instanceMatrix[1].xy*0.585;
  vec2 leaf = p.xy-attachment;
  float angle = sin(uTravel*1.3+n*1.4+branch*0.8)*(0.12+uMid*0.12)
    +(mod(n,2.0)*2.0-1.0)*uBass*0.16
    +sin(uTravel*6.0+vSeed)*uHigh*0.04;
  leaf *= 1.0+uMid*0.09;
  leaf = rotation(cos(angle),sin(angle))*leaf;
  p.xy = attachment+leaf+hothouseSway(n,depth)*at;
  vPage = p.xy;
  gl_Position = vec4(p.x*2.0/(uSize.x/uSize.y),(p.y-0.5)*2.0,0.0,1.0);
}
