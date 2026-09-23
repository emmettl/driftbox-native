#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// A projected miniature landscape: three depths of scenery, slowly changing seasons, drifting
// cloud shadows and an imperfectly registered image inside a physical slide.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

float daydreamHill(float x,float layer) {
  return 0.2+layer*0.14+sin(x*2.5+layer*1.7)*0.045+sin(x*6.0-layer)*0.018;
}
void main() {
  float aspect=uSize.x/uSize.y;
  vec2 frame=abs(vUv-vec2(0.5,0.55))-vec2(0.45,0.34);
  float mount=1.0-smoothstep(0.0,0.006,max(frame.x,frame.y));
  vec3 col=vec3(0.07,0.075,0.085);
  col+=vec3(0.08,0.06,0.035)*exp(-length((vUv-vec2(0.5,0.6))*vec2(1.0,1.4))*4.0);
  col=mix(col,vec3(0.8,0.76,0.64),mount);
  vec2 uv=(vUv-vec2(0.075,0.235))/vec2(0.85,0.625);
  float inside=step(0.0,uv.x)*step(uv.x,1.0)*step(0.0,uv.y)*step(uv.y,1.0);
  vec2 p=vec2((uv.x-0.5)*aspect,uv.y);
  float flutter=sin(uTravel*8.0)*0.0015+sin(uTravel*3.1)*0.001;
  p+=vec2(flutter,flutter*0.6);
  float season=0.5+0.5*sin(uTravel*0.09-0.8);
  vec3 sky=mix(vec3(0.58,0.72,0.72),vec3(0.85,0.65,0.48),season);
  sky=mix(sky,vec3(0.94,0.85,0.66),pow(1.0-uv.y,2.0));
  float sun=1.0-smoothstep(0.059,0.066,length(p-vec2(aspect*0.19,0.76)));
  sky=mix(sky,vec3(1.0,0.9,0.67),sun*0.75);
  float cloud=sin(p.x*5.0+uTravel*0.19)+sin(p.x*10.0-uTravel*0.12+p.y*8.0);
  sky+=smoothstep(0.8,1.8,cloud)*smoothstep(0.5,0.8,p.y)*vec3(0.1,0.08,0.06);
  for(int i=0;i<3;i++) {
    float layer=float(2-i);
    float x=p.x+uTravel*0.003*(3.0-layer)+(uTouch.x-0.5)*uTouch.z*0.09*(3.0-layer);
    float h=daydreamHill(x,layer);
    vec3 land=mix(vec3(0.24,0.4,0.3),vec3(0.57,0.39,0.22),season);
    land=mix(land,sky,layer*0.2);
    float furrows=sin(x*75.0+p.y*130.0);
    land+=vec3(0.025,0.023,0.01)*furrows;
    sky=mix(sky,land,1.0-smoothstep(h,h+0.003,p.y));
    // A lane of trees at each depth; nearby crowns sway visibly with the low end.
    float cell=floor(x*8.0+layer*1.3), local=fract(x*8.0+layer*1.3)-0.5;
    float treeX=(cell+0.5-layer*1.3)/8.0;
    float ground=daydreamHill(treeX,layer)-0.012;
    float height=0.065+hash(vec2(cell,layer))*0.05;
    vec2 q=vec2(local/8.0,p.y-ground);
    q.x+=sin(uTravel*0.8+cell)*uBass*0.011*smoothstep(0.0,height,q.y);
    float trunk=(1.0-smoothstep(0.001,0.0025,abs(q.x)))*step(0.0,q.y)*step(q.y,height);
    float crown=1.0-smoothstep(0.02,0.026,length((q-vec2(0.0,height))*vec2(1.0,0.65)));
    vec3 foliage=mix(vec3(0.18,0.3,0.22),vec3(0.53,0.25,0.15),season);
    sky=mix(sky,foliage+layer*0.06,max(trunk,crown)*0.9);
  }
  // The projector is brightest in the centre. Touch brings a patch into focus.
  float focus=exp(-dot(vUv-uTouch.xy,vUv-uTouch.xy)*28.0)*uTouch.z;
  float grain=(hash(floor(vUv*uSize)+floor(uTime*10.0))-0.5)*0.035*(1.0-focus*0.7);
  sky=mix(sky,vec3(0.85,0.75,0.55),0.12*(1.0-focus));
  sky*=0.8+0.2*exp(-dot(uv-0.5,uv-0.5)*2.0);
  sky+=grain+uMid*0.025;
  col=mix(col,sky,inside);
  // Small registration marks around the mount, like a slide held in a carrier.
  float mark=step(0.04,vUv.x)*step(vUv.x,0.09)*step(0.89,vUv.y)*step(vUv.y,0.893);
  col=mix(col,vec3(0.45,0.4,0.3),mark);
  { fragColor = vec4(col,1.0); return; }
}
