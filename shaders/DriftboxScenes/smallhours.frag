#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// The moving city is behind the glass. Each bead samples it again through a curved offset, so
// passing lights actually bend inside droplets instead of sitting on top.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

vec3 smallHoursOutside(vec2 p) {
  vec3 col=mix(vec3(0.012,0.023,0.052),vec3(0.055,0.105,0.13),smoothstep(-0.5,0.4,p.y));
  for(int i=0;i<9;i++) {
    float n=float(i), seed=hash(vec2(n,7.0));
    float x=mod(n*0.37-uTravel*(0.09+seed*0.06)+3.0,3.4)-1.7;
    float y=-0.13+seed*0.43;
    vec2 d=p-vec2(x,y);
    vec3 light=mix(vec3(0.18,0.65,0.65),vec3(1.0,0.49,0.17),step(0.45,seed));
    float core=exp(-dot(d*vec2(1.0,1.8),d*vec2(1.0,1.8))*650.0);
    float halo=exp(-dot(d,d)*55.0);
    float reflected=exp(-d.x*d.x*480.0)*exp(-abs(p.y+0.3)*8.0)*0.23;
    col+=light*(core*0.95+halo*0.22+reflected)*(0.75+uMid*0.45);
  }
  // Distant, softly focused illuminated carriage windows.
  vec2 q=vec2(p.x+uTravel*0.13,p.y);
  float windows=smoothstep(0.03,0.06,abs(fract(q.x*5.0)-0.5));
  col+=vec3(0.25,0.23,0.15)*windows*exp(-pow((q.y+0.04)*30.0,4.0))*0.35;
  return col;
}
void main() {
  float aspect=uSize.x/uSize.y;
  vec2 p=(vUv-vec2(0.5,0.53))*vec2(aspect,1.0);
  vec2 refraction=vec2(0.0);float beads=0.0,edge=0.0,shine=0.0,trail=0.0;
  float clear=exp(-dot((vUv-uTouch.xy)*vec2(aspect,1.0),(vUv-uTouch.xy)*vec2(aspect,1.0))*65.0)*uTouch.z;
  for(int layer=0;layer<2;layer++) {
    float scale=layer==0?22.0:37.0;
    vec2 uv=p*scale;
    float lane=floor(uv.x);
    float speed=0.28+hash(vec2(lane,float(layer)))*0.8;
    uv.y+=uTravel*speed;
    vec2 id=floor(uv),q=fract(uv)-0.5;
    float seed=hash(id+float(layer)*5.0);
    q.x+=(hash(id+3.0)-0.5)*0.55;
    q.y+=(seed-0.5)*0.4;
    float radius=0.1+seed*0.1;
    vec2 d=q*vec2(1.0,0.8);
    float dist=length(d);
    float drop=(1.0-smoothstep(radius-0.025,radius,dist))*step(0.22,seed)*(1.0-clear);
    refraction+=d*drop*0.3;
    beads=max(beads,drop);
    edge+=exp(-pow((dist-radius)*75.0,2.0))*drop*0.28;
    shine+=exp(-dot(d-vec2(-radius*0.3,radius*0.4),d-vec2(-radius*0.3,radius*0.4))*2300.0)*drop;
    trail+=exp(-q.x*q.x*1800.0)*smoothstep(radius,0.5,q.y)*step(0.68,seed)*(1.0-clear);
  }
  vec3 col=smallHoursOutside(p+refraction);
  col=mix(col,vec3(0.11,0.16,0.18),0.15*(1.0-clear)*(1.0-beads));
  col*=1.0-beads*0.12;
  col+=vec3(0.35,0.65,0.7)*(edge*1.3+shine*0.7+trail*0.12);
  // A breathing reflection from the carriage interior and a dark window gasket.
  col+=vec3(0.16,0.09,0.045)*exp(-pow((vUv.y-0.87)*55.0,2.0))*(0.7+uBass*0.4);
  float rim=min(min(vUv.x,1.0-vUv.x)*aspect,min(vUv.y,1.0-vUv.y));
  col*=smoothstep(0.009,0.035,rim);
  col+=vec3(0.035,0.065,0.07)*exp(-pow((rim-0.025)*220.0,2.0));
  col*=0.5+0.5*smoothstep(0.02,0.24,vUv.y);
  { fragColor = vec4(col*1.18,1.0); return; }
}
