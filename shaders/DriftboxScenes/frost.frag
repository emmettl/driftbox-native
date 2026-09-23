#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// A dawn behind frosted glass, and eleven ice crystals that grow with the mids and pulse with
// each hit; a finger's warmth clears them.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 p=vec2((vUv.x-0.5)*uSize.x/uSize.y,vUv.y-0.5);
  vec2 light=vec2(0.08*sin(uTravel*0.07),0.16);
  float dawn=exp(-dot(p-light,p-light)*5.0);
  vec3 col=mix(vec3(0.025,0.065,0.12),vec3(0.6,0.48,0.3),dawn*0.8);
  col+=vec3(0.14,0.14,0.12)*exp(-dot(p-light,p-light)*35.0)*(0.7+uMid);
  col+=(hash(floor(vUv*uSize))-0.5)*0.014;
  col*=0.65+0.35*smoothstep(0.04,0.24,vUv.y);
  { fragColor = vec4(col,1.0); return; }
}
