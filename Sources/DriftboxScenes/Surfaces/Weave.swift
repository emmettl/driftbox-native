#if canImport(Metal)
  import simd

  /// A cloth with real over/under crossings. Fifteen and sixteen advancing threads draw a
  /// changing motif; dragging bows the fabric locally without moving its wooden frame.
  public final class Weave: SurfaceScene {
    override public class var id: String { "weave" }
    override public class var name: String { "Weave" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 237, 196) / 255 }
    override public class var fragmentFunction: String { "weave" }

    static let source = """

      fragment float4 weave(Full in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float aspect = uSize.x/uSize.y;
        float2 p = float2((vUv.x-0.5)*aspect, vUv.y-0.5);
        float halfWidth = min(aspect*0.40,0.69);
        float halfHeight = 0.34;
        float2 finger = float2((uTouch.x-0.5)*aspect,uTouch.y-0.5);
        float2 delta = p-finger;
        float2 q = p+delta*exp(-dot(delta,delta)*18.0)*uTouch.z*0.45;
        float grain = hash(floor(vUv*uSize))*0.035;
        float3 col = float3(0.92,0.86,0.73)+grain;
        // The loom rests on an indigo workbench, also keeping the player's pale captions legible.
        col = mix(float3(0.14,0.21,0.27)+grain,col,smoothstep(0.11,0.18,vUv.y));
        float2 edge = abs(p)-float2(halfWidth+0.045,halfHeight+0.038);
        float frame = (1.0-smoothstep(0.008,0.014,max(edge.x,edge.y)))
          *smoothstep(-0.013,-0.008,max(edge.x,edge.y));
        col = mix(col,float3(0.38,0.24,0.15)+grain,frame);
        // Fixed thread count across the cloth keeps the same subject legible on a phone.
        float2 grid = float2(q.x/halfWidth*16.0,q.y/halfHeight*24.0);
        float2 cell = floor(grid);
        float2 f = fract(grid);
        float warp = 1.0-smoothstep(0.24,0.32,abs(f.x-0.5));
        float weft = 1.0-smoothstep(0.25,0.34,abs(f.y-0.5));
        float motion = uBeat*4.0;
        float phase15 = mod(floor(motion),15.0);
        float phase16 = mod(floor(motion),16.0);
        // Replace one row at a time, leaving the preceding marks intact as the shuttle
        // advances. Changing every row together would flash a new cloth on each bar.
        float row = mod(cell.y+24.0,48.0);
        float generation = floor(motion/48.0)-step(mod(motion,48.0),row);
        float motif = mod(cell.x+cell.y+generation*3.0,7.0);
        float3 indigo = float3(0.16,0.26,0.37);
        float3 rust = float3(0.73,0.26,0.14);
        float3 flax = float3(0.79,0.68,0.49);
        float3 vertical = mix(indigo,flax,step(4.5,mod(cell.x,8.0)));
        float3 horizontal = mix(rust,flax,step(3.5,motif));
        vertical += exp(-pow((mod(cell.x+16.0,16.0)-phase16)*0.8,2.0))*uBass*0.15;
        horizontal += exp(-pow((mod(cell.y+30.0,15.0)-phase15)*0.8,2.0))*uMid*0.2;
        float over = mod(cell.x+cell.y,2.0);
        // Cylindrical shading and fine twisted fibres keep it recognisably cloth at rest.
        vertical *= 0.64+0.36*sqrt(max(0.0,1.0-pow((f.x-0.5)*2.0,2.0)));
        horizontal *= 0.64+0.36*sqrt(max(0.0,1.0-pow((f.y-0.5)*2.0,2.0)));
        vertical += 0.024*sin(grid.y*48.0+grid.x*16.0);
        horizontal += 0.025*sin(grid.x*48.0-grid.y*16.0);
        float3 cloth = float3(0.24,0.22,0.19);
        if(over<0.5) {
          cloth = mix(cloth,horizontal*(1.0-warp*0.22),weft);
          cloth = mix(cloth,vertical,warp);
        } else {
          cloth = mix(cloth,vertical*(1.0-weft*0.22),warp);
          cloth = mix(cloth,horizontal,weft);
        }
        float inside = (1.0-smoothstep(halfWidth,halfWidth+0.002,abs(q.x)))
          *(1.0-smoothstep(halfHeight,halfHeight+0.002,abs(q.y)));
        // Exposed warp ends above and below the fabric, still fixed to the loom.
        float ends = (1.0-smoothstep(halfWidth,halfWidth+0.002,abs(p.x)))
          *(1.0-smoothstep(halfHeight+0.03,halfHeight+0.035,abs(p.y)));
        float strand = 1.0-smoothstep(0.035,0.09,abs(fract(p.x/halfWidth*16.0)-0.5));
        col = mix(col,flax*0.78,ends*strand);
        col = mix(col,cloth+grain,inside);
        // A quiet shuttle follows the advancing row beneath the cloth.
        float shuttleX = sin(uBeat*0.19635)*halfWidth*0.7;
        float shuttle = 1.0-smoothstep(0.0,0.003,
          length((p-float2(shuttleX,-0.415))*float2(0.3,1.0))-0.011);
        col = mix(col,flax,shuttle);
        return float4(col,1.0);
      }

      """
  }
#endif
