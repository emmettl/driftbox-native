#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Each of Frost's cards, drawn over the surface with straight alpha.
layout(location = 0) in vec2 vUv;
layout(location = 1) in vec2 vPage;
layout(location = 2) in float vSeed;
layout(location = 0) out vec4 fragColor;

void main() {
  vec2 p=(vUv-0.5)*2.0;
  float angle=floor((atan(p.y,p.x)+0.523599)/1.047198)*1.047198;
  vec2 q=rotation(cos(angle),sin(angle))*p;
  q.y=abs(q.y);
  float growth=0.27+0.6*(0.5+0.5*sin(uTravel*0.15+vSeed*1.2))+uMid*0.14;
  float d=line(q,vec2(0.0),vec2(growth,0.0));
  for(int j=1;j<6;j++) {
    float start=float(j)*0.135;
    float reach=clamp((growth-start)*2.5,0.0,1.0);
    if(reach>0.01) {
      vec2 end=vec2(start+0.13*reach,0.22*reach);
      d=min(d,line(q,vec2(start,0.0),end));
      vec2 bud=mix(vec2(start,0.0),end,0.55);
      d=min(d,line(q,bud,bud+vec2(-0.035,0.075)*reach));
    }
  }
  float needle=1.0-smoothstep(0.002,0.007,d);
  float halo=exp(-d*65.0)*0.13;
  vec2 finger=vec2((uTouch.x-0.5)*uSize.x/uSize.y,uTouch.y);
  float warmth=exp(-dot(vPage-finger,vPage-finger)*23.0)*uTouch.z;
  float pulse=0.0;
  for(int h=0;h<8;h++) {
    float age=uTime-uHits[h].x;
    pulse+=exp(-pow((length(p)-age*0.6)*9.0,2.0))*exp(-age)*uHits[h].y;
  }
  vec3 ice=mix(vec3(0.52,0.75,0.9),vec3(0.92,0.88,0.7),warmth);
  ice+=pulse*vec3(0.18,0.2,0.2);
  float alpha=(needle*0.68+halo)*(1.0-warmth)*smoothstep(0.06,0.22,vPage.y);
  { fragColor = vec4(ice,alpha); return; }
}
