#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Each of Hothouse's cards, drawn over the surface with straight alpha.
layout(location = 0) in vec2 vUv;
layout(location = 1) in vec2 vPage;
layout(location = 2) in float vSeed;
layout(location = 0) out vec4 fragColor;

vec3 hothouseGlass(vec3 col, vec2 p) {
  float aspect = uSize.x/uSize.y;
  vec2 uv = vec2(p.x/aspect+0.5,p.y);
  vec2 finger = vec2((uTouch.x-0.5)*aspect,uTouch.y);
  float wipe = exp(-dot(p-finger,p-finger)*18.0)*uTouch.z;
  float mist = (0.09+0.13*sin(p.x*3.0+p.y*2.0))*(1.0-wipe);
  col = mix(col,vec3(0.76,0.79,0.64),mist);
  vec2 drops = p*vec2(72.0,50.0);
  vec2 id = floor(drops), f = fract(drops)-0.5;
  f -= (vec2(hash(id),hash(id+4.0))-0.5)*0.55;
  float d = length(f*vec2(1.0,0.7));
  float droplet = (1.0-smoothstep(0.06,0.11,d))*step(0.76,hash(id+7.0))*(1.0-wipe);
  col += droplet*vec3(0.13,0.15,0.12);
  col += hash(floor(uv*uSize))*0.028;
  return col*(0.84+0.16*sqrt(max(0.0,1.0-length((uv-0.5)*1.2))));
}
void main() {
  vec2 q = (vUv-0.5)*2.0;
  float profile = length(vec2(q.x*(1.0+0.4*abs(q.y)),q.y));
  float alpha = 1.0-smoothstep(0.94,1.0,profile);
  if(alpha<0.01) discard;
  float mainVein = 1.0-smoothstep(0.015,0.04,abs(q.x));
  float branches = 1.0-smoothstep(0.025,0.06,abs(fract(q.y*4.5-abs(q.x)*2.4)-0.5));
  float vein = max(mainVein,branches*0.5);
  float glow = 0.0;
  for(int h=0;h<8;h++) {
    float age = uTime-uHits[h].x;
    glow += exp(-pow((vPage.y+0.1-age*0.85)*8.0,2.0))*exp(-age*0.7)*uHits[h].y;
  }
  vec3 green = mix(vec3(0.18,0.36,0.23),vec3(0.43,0.5,0.23),hash(vec2(vSeed,19.0)));
  green *= 0.7+0.3*(1.0-profile);
  green += vein*(vec3(0.08,0.1,0.02)+vec3(1.25,0.83,0.2)*glow);
  green += vec3(0.08,0.06,0.01)*glow;
  green += vec3(0.04,0.045,0.0)*q.x;
  { fragColor = vec4(hothouseGlass(green,vPage),alpha*0.93); return; }
}
