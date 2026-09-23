#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// The glass and ironwork occupy a single surface. Leaves are instanced cards: a leaf shader
// runs only where that leaf is drawn, instead of evaluating every leaf at every pixel.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

// Shared by the stems and their leaves: the whole plant leans, with its root fixed.
vec2 hothouseSway(float n, float depth) {
  float side = mod(n,2.0)*2.0-1.0;
  float breeze = sin(uTravel*0.95+n*0.83)*(0.025+depth*0.055);
  float bassLean = side*uBass*(0.014+depth*0.035);
  float lift = sin(uTravel*0.72+n*0.61)*0.014*(0.3+depth)*(0.4+uMid);
  return vec2(breeze+bassLean,lift);
}
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
  float aspect = uSize.x/uSize.y;
  vec2 p = vec2((vUv.x-0.5)*aspect,vUv.y);
  vec3 col = mix(vec3(0.13,0.24,0.19),vec3(0.86,0.72,0.4),pow(vUv.y,0.75));
  float sun = exp(-length((p-vec2(aspect*0.2,0.79))*vec2(2.0,1.0))*5.0);
  col += vec3(0.28,0.18,0.06)*sun;
  // Receding iron ribs, with a central roof ridge. No raymarching.
  for(int i=0;i<7;i++) {
    float z = float(i)/6.0;
    float w = 0.12+z*z*max(0.65,aspect*0.62);
    float roof = 0.64+z*0.44;
    float eave = 0.6+z*0.17;
    float rib = min(line(p,vec2(-w,-0.1),vec2(-w,eave)),line(p,vec2(w,-0.1),vec2(w,eave)));
    rib = min(rib,line(p,vec2(-w,eave),vec2(0.0,roof)));
    rib = min(rib,line(p,vec2(w,eave),vec2(0.0,roof)));
    col = mix(col,vec3(0.18,0.27,0.21),(1.0-smoothstep(0.002,0.004+z*0.003,rib))*(0.18+z*0.44));
  }
  float path = 1.0-smoothstep(0.04,0.07,abs(p.x)/max(0.08,0.65-p.y));
  col = mix(col,vec3(0.48,0.45,0.3),path*(1.0-smoothstep(0.5,0.59,p.y))*0.5);
  for(int i=0;i<12;i++) {
    float n = float(i), side = mod(n,2.0)*2.0-1.0, depth = floor(n/2.0)/6.0;
    vec2 root = vec2(side*(0.07+depth*min(aspect*0.65,0.8)),0.45-depth*0.52);
    vec2 tip = root+vec2(side*(0.035+depth*0.12),0.13+depth*0.67);
    tip += hothouseSway(n,depth);
    float stem = 1.0-smoothstep(0.001,0.003,line(p,root,tip));
    col = mix(col,vec3(0.2,0.32,0.16),stem);
  }
  { fragColor = vec4(hothouseGlass(col,p),1.0); return; }
}
