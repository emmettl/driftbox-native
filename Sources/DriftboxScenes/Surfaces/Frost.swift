#if canImport(Metal)
  import simd

  /// A dawn behind frosted glass, and eleven ice crystals that grow with the mids and pulse with
  /// each hit; a finger's warmth clears them.
  public final class Frost: SurfaceScene {
    override public class var id: String { "frost" }
    override public class var name: String { "Frost" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 202, 133) / 255 }
    override public class var fragmentFunction: String { "frostBackground" }
    override public class var cardFunctions: (vertex: String, fragment: String)? {
      ("frostVertex", "frostCrystal")
    }

    static let placements: [(x: Float, y: Float, scale: Float)] = [
      (0.02, 0.3, 0.38), (0.04, 0.65, 0.34), (0.17, 0.94, 0.38), (0.52, 1.04, 0.42),
      (0.88, 0.93, 0.38), (0.99, 0.64, 0.38), (0.99, 0.27, 0.4), (0.66, 0.02, 0.32),
      (0.27, 0.03, 0.3), (0.26, 0.47, 0.19), (0.74, 0.53, 0.2),
    ]

    override public func cards(aspect: Float) -> [simd_float4x4] {
      Self.placements.enumerated().map { index, place in
        Self.compose(
          x: (place.x - 0.5) * aspect, y: place.y, z: Float(index), angle: Float(index) * 0.71,
          scale: SIMD2(place.scale, place.scale))
      }
    }

    static let source = """

      fragment float4 frostBackground(Full in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float2 p=float2((vUv.x-0.5)*uSize.x/uSize.y,vUv.y-0.5);
        float2 light=float2(0.08*sin(uTravel*0.07),0.16);
        float dawn=exp(-dot(p-light,p-light)*5.0);
        float3 col=mix(float3(0.025,0.065,0.12),float3(0.6,0.48,0.3),dawn*0.8);
        col+=float3(0.14,0.14,0.12)*exp(-dot(p-light,p-light)*35.0)*(0.7+uMid);
        col+=(hash(floor(vUv*uSize))-0.5)*0.014;
        col*=0.65+0.35*smoothstep(0.04,0.24,vUv.y);
        return float4(col,1.0);
      }

      vertex Card frostVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]], constant SurfaceUniforms &u [[buffer(0)]],
        constant float4x4 *instances [[buffer(1)]]
      ) {
        float4x4 instanceMatrix=instances[iid];
        float2 position=cardCorners[vid];
        Card out;
        out.uv=(position+1.0)*0.5;
        out.vSeed=instanceMatrix[3].z;
        float4 p=instanceMatrix*float4(position,0.0,1.0);
        out.vPage=p.xy;
        out.position=float4(p.x*2.0/(u.size.x/u.size.y),(p.y-0.5)*2.0,0.0,1.0);
        return out;
      }

      fragment float4 frostCrystal(Card in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float2 vPage=in.vPage; float vSeed=in.vSeed;
        float2 p=(vUv-0.5)*2.0;
        float angle=floor((atan2(p.y,p.x)+0.523599)/1.047198)*1.047198;
        float2 q=rotation(cos(angle),sin(angle))*p;
        q.y=abs(q.y);
        float growth=0.27+0.6*(0.5+0.5*sin(uTravel*0.15+vSeed*1.2))+uMid*0.14;
        float d=line(q,float2(0.0),float2(growth,0.0));
        for(int j=1;j<6;j++) {
          float start=float(j)*0.135;
          float reach=clamp((growth-start)*2.5,0.0,1.0);
          if(reach>0.01) {
            float2 end=float2(start+0.13*reach,0.22*reach);
            d=min(d,line(q,float2(start,0.0),end));
            float2 bud=mix(float2(start,0.0),end,0.55);
            d=min(d,line(q,bud,bud+float2(-0.035,0.075)*reach));
          }
        }
        float needle=1.0-smoothstep(0.002,0.007,d);
        float halo=exp(-d*65.0)*0.13;
        float2 finger=float2((uTouch.x-0.5)*uSize.x/uSize.y,uTouch.y);
        float warmth=exp(-dot(vPage-finger,vPage-finger)*23.0)*uTouch.z;
        float pulse=0.0;
        for(int h=0;h<8;h++) {
          float age=uTime-uHits[h].x;
          pulse+=exp(-pow((length(p)-age*0.6)*9.0,2.0))*exp(-age)*uHits[h].y;
        }
        float3 ice=mix(float3(0.52,0.75,0.9),float3(0.92,0.88,0.7),warmth);
        ice+=pulse*float3(0.18,0.2,0.2);
        float alpha=(needle*0.68+halo)*(1.0-warmth)*smoothstep(0.06,0.22,vPage.y);
        return float4(ice,alpha);
      }

      """
  }
#endif
