#version 450
#extension GL_GOOGLE_include_directive : require
#include "surface.glsl"
// Printed paper, lit along the cut edges. The camera stays above a layered town; the
// foreground folds away under a finger, revealing streets further back.
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

vec3 paperCitiesPaper(float layer) {
  if (layer < 0.5) return vec3(0.73,0.72,0.62);
  if (layer < 1.5) return vec3(0.76,0.48,0.36);
  if (layer < 2.5) return vec3(0.39,0.49,0.48);
  if (layer < 3.5) return vec3(0.68,0.31,0.22);
  return vec3(0.19,0.29,0.31);
}
void main() {
  float aspect = uSize.x/uSize.y;
  vec2 p = vec2((vUv.x-0.5)*aspect, vUv.y);
  float grain = hash(floor(vUv*uSize))*0.035;
  vec3 col = vec3(0.94,0.88,0.75) + grain;
  vec2 sun = p-vec2(min(aspect*0.26,0.57),0.77);
  float disk = 1.0-smoothstep(0.119,0.122,length(sun));
  col = mix(col,vec3(0.83,0.41,0.25)+grain,disk*0.85);
  // A faint misregistered second print around the sun.
  float halo = 1.0-smoothstep(0.001,0.003,abs(length(sun+vec2(0.012,0.006))-0.142));
  col = mix(col,vec3(0.69,0.59,0.43),halo*0.35);
  for (int i=0;i<5;i++) {
    float layer = float(i);
    float scale = 5.0-layer*0.48;
    vec2 q = p;
    q.x += uTravel*0.003*(layer+1.0);
    float peel = exp(-pow((vUv.x-uTouch.x)*4.0,2.0))*uTouch.z;
    q.y += peel*0.12*max(0.0,layer-2.0);
    float cell = floor(q.x*scale);
    float x = fract(q.x*scale);
    float rnd = hash(vec2(cell,layer+4.0));
    float base = 0.43-layer*0.105;
    float roof = base+0.13+rnd*0.19;
    // Small folded hinges breathe with the bass, never a whole-city zoom.
    roof += uBass*0.022*sin(cell*1.7+layer);
    float pitch = (1.0-abs(x-0.5)*2.0)*(0.035+0.035*step(0.45,rnd));
    float torn = sin(q.x*410.0+layer)*0.0012 + sin(q.x*179.0)*0.001;
    float edge = roof+pitch+torn;
    float body = (1.0-smoothstep(edge,edge+0.002,q.y))*smoothstep(0.04,0.05,x)
      *(1.0-smoothstep(0.94,0.95,x));
    // The strip joining the buildings is also paper, so no floating houses.
    body = max(body,1.0-smoothstep(base,base+0.002,q.y));
    float shadow = (1.0-smoothstep(edge+0.008,edge+0.018,q.y))
      *smoothstep(0.045,0.06,x)*(1.0-smoothstep(0.96,0.98,x));
    col *= 1.0-shadow*0.16;
    vec3 ink = paperCitiesPaper(layer)+grain;
    float cut = (1.0-smoothstep(0.0,0.004,abs(q.y-edge)))*0.35;
    ink += cut;
    ink *= 0.92+0.08*smoothstep(0.05,0.16,x);
    vec2 win = vec2(x*5.0,(q.y-base)*24.0);
    vec2 fw = fract(win);
    float windows = smoothstep(0.25,0.3,fw.x)*(1.0-smoothstep(0.64,0.69,fw.x))
      *smoothstep(0.18,0.23,fw.y)*(1.0-smoothstep(0.63,0.68,fw.y));
    windows *= step(base+0.04,q.y)*(1.0-step(roof-0.018,q.y))*step(0.14,x)*(1.0-step(0.87,x));
    float lit = step(0.53,hash(vec2(cell*9.0+floor(win.x),floor(win.y)+layer*13.0)));
    vec3 windowInk = mix(ink*0.5,vec3(0.96,0.81,0.52)*(0.9+uMid*0.2),lit);
    ink = mix(ink,windowInk,windows*0.8);
    // Visible paper fibres and a sparse diagonal hatch rather than photographic noise.
    float hatch = step(0.92,fract((q.x+q.y)*180.0));
    ink -= hatch*0.025;
    col = mix(col,ink,body);
  }
  col *= 1.0-0.12*pow(abs(vUv.x-0.5)*2.0,3.0);
  { fragColor = vec4(col,1.0); return; }
}
