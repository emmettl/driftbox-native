#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Three geared orbits share the score's 5-, 7- and 4-beat periods. The transport supplies the
// position, so opening the scene mid-phrase or seeking preserves alignment.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
  float aspect=uSize.x/uSize.y;
  float fit=min(aspect,1.35);
  vec2 p=(vUv-vec2(0.5,0.55))*vec2(aspect,1.0)/fit;
  float tilt=mix(1.04,0.66,smoothstep(0.5,1.2,aspect))+(uTouch.y-0.5)*uTouch.z*0.22;
  float turn=(uTouch.x-0.5)*uTouch.z*0.3;
  p=rotation(cos(turn),sin(turn))*p;
  vec2 q=p/vec2(1.0,tilt);
  float r=length(q),theta=atan(q.y,q.x);
  float aa=1.5/uSize.y/fit;
  vec3 brass=vec3(0.78,0.52,0.23), mint=vec3(0.27,0.82,0.77);
  vec3 col=vec3(0.015,0.029,0.04)+vec3(0.04,0.055,0.055)*exp(-r*r*5.0);
  vec2 starCell=floor(vUv*uSize/75.0);
  vec2 star=fract(vUv*uSize/75.0)-vec2(hash(starCell),hash(starCell+8.0));
  col+=vec3(0.25,0.35,0.38)*exp(-dot(star,star)*2200.0)*step(0.6,hash(starCell+2.0));
  float rim=exp(-pow((r-0.43)/aa,2.0));
  float ticks=pow(max(0.0,cos(theta*120.0)),30.0)*smoothstep(0.405,0.41,r)*(1.0-smoothstep(0.425,0.43,r));
  col+=brass*(rim*0.45+ticks*0.4);
  col+=brass*exp(-pow((r-0.39)/aa,2.0))*0.14;
  float phase=uScoreBeat;
  float conjunction=pow(max(0.0,cos(phase*6.2831853/35.0)),100.0);
  for(int i=0;i<3;i++) {
    float n=float(i),period=i==0?5.0:(i==1?7.0:4.0);
    float radius=0.17+n*0.09;
    float angle=phase/period*6.2831853+1.5707963;
    vec2 body=vec2(cos(angle),sin(angle))*radius;
    vec3 colour=i==0?vec3(0.98,0.71,0.35):(i==1?mint:vec3(0.85,0.88,0.78));
    float level=i==0?uMid:(i==1?uBass:uHigh);
    float orbit=exp(-pow((r-radius)/aa,2.0));
    col+=colour*orbit*0.35;
    float arm=line(q,vec2(0.0),body);
    col+=brass*exp(-pow(arm/(aa*0.7),2.0))*0.36;
    // A short engraved tail shows direction even when the transport is paused.
    float arc=mod(angle-theta+6.2831853,6.2831853);
    col+=colour*orbit*exp(-arc*3.0)*1.3;
    vec2 d=(q-body)*vec2(1.0,tilt);
    float size=0.013+n*0.003+level*0.006;
    float ball=1.0-smoothstep(size-aa,size+aa,length(d));
    float light=0.3+0.7*clamp(0.5+dot(d/size,vec2(-0.55,0.7)),0.0,1.0);
    col=mix(col,colour*light,ball);
    col+=colour*exp(-dot(d,d)/(size*size*5.0))*(0.1+level*0.26);
    col+=vec3(1.0,0.92,0.75)*exp(-dot(d-vec2(-size*0.3,size*0.35),d-vec2(-size*0.3,size*0.35))/(size*size*0.055))*0.5;
  }
  float hub=length(p);
  col+=brass*exp(-pow((hub-0.03)/aa,2.0))*0.8;
  col+=vec3(1.0,0.69,0.3)*exp(-hub*hub*1800.0)*(0.45+uMid*0.3+conjunction*0.55);
  col+=brass*exp(-pow((r-0.38-conjunction*0.012)/0.007,2.0))*conjunction*0.12;
  col*=0.55+0.45*smoothstep(0.06,0.24,vUv.y);
  { fragColor = vec4(col,1.0); return; }
}
