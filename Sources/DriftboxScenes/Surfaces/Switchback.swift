#if canImport(Metal)
  import simd

  /// Isometric stair ribbons, with a short sideways cut each bar. The colour stays steady through
  /// a cut; percussion raises individual treads instead of flashing the whole field.
  public final class Switchback: SurfaceScene {
    override public class var id: String { "switchback" }
    override public class var name: String { "Switchback" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 250, 224) / 255 }
    override public class var fragmentFunction: String { "switchback" }

    static let source = """

      static float switchbackPath(float2 f) {
        return min(line(f,float2(0.0,0.5),float2(0.5,0.5)),line(f,float2(0.5,0.5),float2(0.5,1.0)));
      }
      static float2 switchbackOrient(float2 p,float turns) {
        if(turns<0.5) return p;
        if(turns<1.5) return float2(p.y,1.0-p.x);
        if(turns<2.5) return 1.0-p;
        return float2(1.0-p.y,p.x);
      }
      fragment float4 switchback(Full in [[stage_in]], constant SurfaceUniforms &u [[buffer(0)]]) {
        \(SurfaceScene.aliases)
        float aspect=uSize.x/uSize.y;
        float2 p=float2((vUv.x-0.5)*aspect,vUv.y-0.5);
        float bar=floor(uBeat/4.0);
        float shift=smoothstep(0.0,0.6,mod(uBeat,4.0));
        float2 before=float2(sin(bar*1.5708),cos(bar*1.5708));
        float2 after=float2(sin((bar+1.0)*1.5708),cos((bar+1.0)*1.5708));
        p+=mix(before,after,shift)*0.15;
        p.y+=uTravel*0.018;
        float2 finger=float2((uTouch.x-0.5)*aspect,uTouch.y-0.5);
        float2 delta=p-finger;
        p+=delta*exp(-dot(delta,delta)*12.0)*uTouch.z*0.5;
        float2 grid=float2(p.x*0.9+p.y,p.y-p.x*0.9)*6.0;
        float2 cell=floor(grid), f=fract(grid);
        float seed=hash(cell);
        float turn=floor(seed*4.0);
        float3 ink=float3(0.035,0.065,0.12);
        float3 tile=seed<0.33?float3(0.08,0.53,0.75):seed<0.67?float3(0.95,0.47,0.16):float3(0.87,0.72,0.26);
        float d=switchbackPath(switchbackOrient(f,turn));
        float raised=0.045+uBass*0.07*step(0.55,seed);
        float side=switchbackPath(switchbackOrient(f+float2(raised),turn));
        float3 col=ink+float3(0.025)*step(0.97,max(f.x,f.y));
        col=mix(col,tile*0.35,1.0-smoothstep(0.16,0.18,side));
        float tread=fract((switchbackOrient(f,turn).x+switchbackOrient(f,turn).y)*8.0);
        float3 top=tile*(0.82+0.18*smoothstep(0.05,0.3,tread));
        top+=float3(0.1)*step(0.84,tread)*uMid;
        col=mix(col,top,1.0-smoothstep(0.16,0.18,d));
        col+=tile*(1.0-smoothstep(0.004,0.016,abs(d-0.15)))*0.2;
        // Small travelling lights pick out the route through the tiles.
        float marker=1.0-smoothstep(0.018,0.032,length(switchbackOrient(f,turn)-float2(0.5,0.5+mod(uBeat+seed,1.0)*0.5)));
        col=mix(col,float3(0.96,0.95,0.82),marker*(0.25+uHigh));
        col*=0.5+0.5*smoothstep(0.08,0.28,vUv.y);
        return float4(col,1.0);
      }

      """
  }
#endif
