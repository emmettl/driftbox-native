#if canImport(Metal)
  import Foundation
  import simd

  /// The glass and ironwork occupy a single surface. Leaves are instanced cards: a leaf shader
  /// runs only where that leaf is drawn, instead of evaluating every leaf at every pixel.
  public final class Hothouse: SurfaceScene {
    override public class var id: String { "hothouse" }
    override public class var name: String { "Hothouse" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 221, 154) / 255 }
    override public class var fragmentFunction: String { "hothouseBackground" }
    override public class var cardFunctions: (vertex: String, fragment: String)? {
      ("hothouseLeafVertex", "hothouseLeaf")
    }

    override public func cards(aspect: Float) -> [simd_float4x4] {
      (0..<36).map { index in
        let n = index / 3
        let branch = index % 3
        let side = Float(n % 2) * 2 - 1
        let depth = Float(n / 2) / 6
        let x = side * (0.07 + depth * min(aspect * 0.65, 0.8))
        let y = 0.45 - depth * 0.52
        let tipX = side * (0.035 + depth * 0.12)
        let tipY = 0.13 + depth * 0.67
        let at = 0.42 + Float(branch) * 0.22
        let angle = side * (0.7 + Float(branch) * 0.52) + sin(Float(n)) * 0.3
        let scale = 0.035 + depth * 0.12
        return Self.compose(
          x: x + tipX * at - sin(angle) * scale * 0.75, y: y + tipY * at + cos(angle) * scale * 0.75,
          z: Float(n) + Float(branch) * 0.1, angle: angle, scale: SIMD2(scale / 1.7, scale / 0.78))
      }
    }

    static let source = """

      // Shared by the stems and their leaves: the whole plant leans, with its root fixed.
      static float2 hothouseSway(float n, float depth, constant SurfaceUniforms &u) {
        float uTravel=u.travel, uBass=u.bass, uMid=u.mid;
        float side = mod(n,2.0)*2.0-1.0;
        float breeze = sin(uTravel*0.95+n*0.83)*(0.025+depth*0.055);
        float bassLean = side*uBass*(0.014+depth*0.035);
        float lift = sin(uTravel*0.72+n*0.61)*0.014*(0.3+depth)*(0.4+uMid);
        return float2(breeze+bassLean,lift);
      }

      static float3 hothouseGlass(float3 col, float2 p, constant SurfaceUniforms &u) {
        float2 uSize=u.size; float3 uTouch=u.touch;
        float aspect = uSize.x/uSize.y;
        float2 uv = float2(p.x/aspect+0.5,p.y);
        float2 finger = float2((uTouch.x-0.5)*aspect,uTouch.y);
        float wipe = exp(-dot(p-finger,p-finger)*18.0)*uTouch.z;
        float mist = (0.09+0.13*sin(p.x*3.0+p.y*2.0))*(1.0-wipe);
        col = mix(col,float3(0.76,0.79,0.64),mist);
        float2 drops = p*float2(72.0,50.0);
        float2 id = floor(drops), f = fract(drops)-0.5;
        f -= (float2(hash(id),hash(id+4.0))-0.5)*0.55;
        float d = length(f*float2(1.0,0.7));
        float droplet = (1.0-smoothstep(0.06,0.11,d))*step(0.76,hash(id+7.0))*(1.0-wipe);
        col += droplet*float3(0.13,0.15,0.12);
        col += hash(floor(uv*uSize))*0.028;
        return col*(0.84+0.16*sqrt(max(0.0,1.0-length((uv-0.5)*1.2))));
      }

      fragment float4 hothouseBackground(Full in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float aspect = uSize.x/uSize.y;
        float2 p = float2((vUv.x-0.5)*aspect,vUv.y);
        float3 col = mix(float3(0.13,0.24,0.19),float3(0.86,0.72,0.4),pow(vUv.y,0.75));
        float sun = exp(-length((p-float2(aspect*0.2,0.79))*float2(2.0,1.0))*5.0);
        col += float3(0.28,0.18,0.06)*sun;
        // Receding iron ribs, with a central roof ridge. No raymarching.
        for(int i=0;i<7;i++) {
          float z = float(i)/6.0;
          float w = 0.12+z*z*max(0.65,aspect*0.62);
          float roof = 0.64+z*0.44;
          float eave = 0.6+z*0.17;
          float rib = min(line(p,float2(-w,-0.1),float2(-w,eave)),line(p,float2(w,-0.1),float2(w,eave)));
          rib = min(rib,line(p,float2(-w,eave),float2(0.0,roof)));
          rib = min(rib,line(p,float2(w,eave),float2(0.0,roof)));
          col = mix(col,float3(0.18,0.27,0.21),(1.0-smoothstep(0.002,0.004+z*0.003,rib))*(0.18+z*0.44));
        }
        float path = 1.0-smoothstep(0.04,0.07,abs(p.x)/max(0.08,0.65-p.y));
        col = mix(col,float3(0.48,0.45,0.3),path*(1.0-smoothstep(0.5,0.59,p.y))*0.5);
        for(int i=0;i<12;i++) {
          float n = float(i), side = mod(n,2.0)*2.0-1.0, depth = floor(n/2.0)/6.0;
          float2 root = float2(side*(0.07+depth*min(aspect*0.65,0.8)),0.45-depth*0.52);
          float2 tip = root+float2(side*(0.035+depth*0.12),0.13+depth*0.67);
          tip += hothouseSway(n,depth,u);
          float stem = 1.0-smoothstep(0.001,0.003,line(p,root,tip));
          col = mix(col,float3(0.2,0.32,0.16),stem);
        }
        return float4(hothouseGlass(col,p,u),1.0);
      }

      vertex Card hothouseLeafVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]], constant SurfaceUniforms &u [[buffer(0)]],
        constant float4x4 *instances [[buffer(1)]]
      ) {
        float uTravel=u.travel, uBass=u.bass, uMid=u.mid, uHigh=u.high;
        float4x4 instanceMatrix=instances[iid];
        float2 position=cardCorners[vid];
        Card out;
        out.uv = (position+1.0)*0.5;
        float vSeed = instanceMatrix[3].z;
        out.vSeed = vSeed;
        float4 p = instanceMatrix*float4(position,0.0,1.0);
        float n = floor(vSeed), branch = floor(fract(vSeed)*10.0+0.5);
        float depth = floor(n/2.0)/6.0;
        float at = 0.42+branch*0.22;
        // Hinge at the leaf's attachment to the stem, rather than sliding the card loose.
        float2 attachment = instanceMatrix[3].xy-instanceMatrix[1].xy*0.585;
        float2 leaf = p.xy-attachment;
        float angle = sin(uTravel*1.3+n*1.4+branch*0.8)*(0.12+uMid*0.12)
          +(mod(n,2.0)*2.0-1.0)*uBass*0.16
          +sin(uTravel*6.0+vSeed)*uHigh*0.04;
        leaf *= 1.0+uMid*0.09;
        leaf = rotation(cos(angle),sin(angle))*leaf;
        p.xy = attachment+leaf+hothouseSway(n,depth,u)*at;
        out.vPage = p.xy;
        out.position = float4(p.x*2.0/(u.size.x/u.size.y),(p.y-0.5)*2.0,0.0,1.0);
        return out;
      }

      fragment float4 hothouseLeaf(Card in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float2 vPage=in.vPage; float vSeed=in.vSeed;
        float2 q = (vUv-0.5)*2.0;
        float profile = length(float2(q.x*(1.0+0.4*abs(q.y)),q.y));
        float alpha = 1.0-smoothstep(0.94,1.0,profile);
        if(alpha<0.01) discard_fragment();
        float mainVein = 1.0-smoothstep(0.015,0.04,abs(q.x));
        float branches = 1.0-smoothstep(0.025,0.06,abs(fract(q.y*4.5-abs(q.x)*2.4)-0.5));
        float vein = max(mainVein,branches*0.5);
        float glow = 0.0;
        for(int h=0;h<8;h++) {
          float age = uTime-uHits[h].x;
          glow += exp(-pow((vPage.y+0.1-age*0.85)*8.0,2.0))*exp(-age*0.7)*uHits[h].y;
        }
        float3 green = mix(float3(0.18,0.36,0.23),float3(0.43,0.5,0.23),hash(float2(vSeed,19.0)));
        green *= 0.7+0.3*(1.0-profile);
        green += vein*(float3(0.08,0.1,0.02)+float3(1.25,0.83,0.2)*glow);
        green += float3(0.08,0.06,0.01)*glow;
        green += float3(0.04,0.045,0.0)*q.x;
        return float4(hothouseGlass(green,vPage,u),alpha*0.93);
      }

      """
  }
#endif
