#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Isometric stair ribbons, with a short sideways cut each bar. The colour stays steady through
// a cut; percussion raises individual treads instead of flashing the whole field.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

float switchbackPath(vec2 f) {
  return min(line(f,vec2(0.0,0.5),vec2(0.5,0.5)),line(f,vec2(0.5,0.5),vec2(0.5,1.0)));
}
vec2 switchbackOrient(vec2 p,float turns) {
  if(turns<0.5) return p;
  if(turns<1.5) return vec2(p.y,1.0-p.x);
  if(turns<2.5) return 1.0-p;
  return vec2(1.0-p.y,p.x);
}
void main() {
  float aspect=uSize.x/uSize.y;
  vec2 p=vec2((vUv.x-0.5)*aspect,vUv.y-0.5);
  float bar=floor(uBeat/4.0);
  float shift=smoothstep(0.0,0.6,mod(uBeat,4.0));
  vec2 before=vec2(sin(bar*1.5708),cos(bar*1.5708));
  vec2 after=vec2(sin((bar+1.0)*1.5708),cos((bar+1.0)*1.5708));
  p+=mix(before,after,shift)*0.15;
  p.y+=uTravel*0.018;
  vec2 finger=vec2((uTouch.x-0.5)*aspect,uTouch.y-0.5);
  vec2 delta=p-finger;
  p+=delta*exp(-dot(delta,delta)*12.0)*uTouch.z*0.5;
  vec2 grid=vec2(p.x*0.9+p.y,p.y-p.x*0.9)*6.0;
  vec2 cell=floor(grid), f=fract(grid);
  float seed=hash(cell);
  float turn=floor(seed*4.0);
  vec3 ink=vec3(0.035,0.065,0.12);
  vec3 tile=seed<0.33?vec3(0.08,0.53,0.75):seed<0.67?vec3(0.95,0.47,0.16):vec3(0.87,0.72,0.26);
  float d=switchbackPath(switchbackOrient(f,turn));
  float raised=0.045+uBass*0.07*step(0.55,seed);
  float side=switchbackPath(switchbackOrient(f+vec2(raised),turn));
  vec3 col=ink+vec3(0.025)*step(0.97,max(f.x,f.y));
  col=mix(col,tile*0.35,1.0-smoothstep(0.16,0.18,side));
  float tread=fract((switchbackOrient(f,turn).x+switchbackOrient(f,turn).y)*8.0);
  vec3 top=tile*(0.82+0.18*smoothstep(0.05,0.3,tread));
  top+=vec3(0.1)*step(0.84,tread)*uMid;
  col=mix(col,top,1.0-smoothstep(0.16,0.18,d));
  col+=tile*(1.0-smoothstep(0.004,0.016,abs(d-0.15)))*0.2;
  // Small travelling lights pick out the route through the tiles.
  float marker=1.0-smoothstep(0.018,0.032,length(switchbackOrient(f,turn)-vec2(0.5,0.5+mod(uBeat+seed,1.0)*0.5)));
  col=mix(col,vec3(0.96,0.95,0.82),marker*(0.25+uHigh));
  col*=0.5+0.5*smoothstep(0.08,0.28,vUv.y);
  { fragColor = vec4(col,1.0); return; }
}
