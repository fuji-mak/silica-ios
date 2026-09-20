//
//  ShipSwiftCardStudioBackgrounds.metal
//  Silica
//
//  Adapted from ShipSwift's SWStarNest and SWPlasma shaders.
//  Source: https://github.com/signerlabs/ShipSwift
//
//  Star Nest is adapted from "Star Nest" by Pablo Roman Andrioli (Kali):
//  https://www.shadertoy.com/view/XlfGRj
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - ShipSwift Star Nest

static float3 swStarNestMod(float3 x, float3 y) {
    return x - y * floor(x / y);
}

[[ stitchable ]] half4 swStarNest(float2 position,
                                  half4  color,
                                  float4 boundingRect,
                                  float  time,
                                  float  speed,
                                  float  zoom,
                                  float  brightness,
                                  float  saturation,
                                  float  darkmatter,
                                  float  distfading,
                                  float  angleX,
                                  float  angleY,
                                  float  volsteps,
                                  float  iterations) {
    const float formuparam = 0.53;
    const float stepsize = 0.1;
    const float tile = 0.850;

    float2 size = boundingRect.zw;
    float2 uv = position / size - 0.5;
    uv.y *= size.y / size.x;
    float3 dir = float3(uv * zoom, 1.0);
    float t = time * speed + 0.25;

    float2x2 rot1 = float2x2(
        float2(cos(angleX), sin(angleX)),
        float2(-sin(angleX), cos(angleX))
    );
    float2x2 rot2 = float2x2(
        float2(cos(angleY), sin(angleY)),
        float2(-sin(angleY), cos(angleY))
    );

    float2 dxz = rot1 * float2(dir.x, dir.z);
    dir.x = dxz.x;
    dir.z = dxz.y;
    float2 dxy = rot2 * float2(dir.x, dir.y);
    dir.x = dxy.x;
    dir.y = dxy.y;

    float3 from = float3(1.0, 0.5, 0.5);
    from += float3(t * 2.0, t, -2.0);
    float2 fxz = rot1 * float2(from.x, from.z);
    from.x = fxz.x;
    from.z = fxz.y;
    float2 fxy = rot2 * float2(from.x, from.y);
    from.x = fxy.x;
    from.y = fxy.y;

    float s = 0.1;
    float fade = 1.0;
    float3 v = float3(0.0);
    int vsteps = clamp(int(volsteps), 1, 24);
    int iters = clamp(int(iterations), 1, 24);

    for (int r = 0; r < vsteps; r++) {
        float3 p = from + s * dir * 0.5;
        p = abs(float3(tile) - swStarNestMod(
            p,
            float3(tile * 2.0)
        ));

        float pa = 0.0;
        float a = 0.0;
        for (int i = 0; i < iters; i++) {
            p = abs(p) / dot(p, p) - formuparam;
            a += abs(length(p) - pa);
            pa = length(p);
        }

        float dm = max(0.0, darkmatter - a * a * 0.001);
        a *= a * a;
        if (r > 6) {
            fade *= 1.0 - dm;
        }

        v += fade;
        v += float3(s, s * s, s * s * s * s)
            * a * brightness * fade;
        fade *= distfading;
        s += stepsize;
    }

    v = mix(float3(length(v)), v, saturation);
    return half4(half3(v * 0.01), 1.0);
}

// MARK: - ShipSwift Plasma / Solar

static float swPlasmaHash(float2 p) {
    p = float2(
        dot(p, float2(91.31, 47.79)),
        dot(p, float2(31.07, 73.13))
    );
    return fract(sin(p.x + p.y) * 19357.713);
}

static float swPlasmaVNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = swPlasmaHash(i);
    float b = swPlasmaHash(i + float2(1.0, 0.0));
    float c = swPlasmaHash(i + float2(0.0, 1.0));
    float d = swPlasmaHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float swPlasmaFBM3(float2 p) {
    float v = swPlasmaVNoise(p) * 0.5;
    v += swPlasmaVNoise(p * 2.0) * 0.3;
    v += swPlasmaVNoise(p * 4.0) * 0.2;
    return v - 0.5;
}

static float3 swPlasmaPal5(float t,
                           float3 c1,
                           float3 c2,
                           float3 c3,
                           float3 c4,
                           float3 c5) {
    t = clamp(t, 0.0, 1.0);
    if (t < 0.25) {
        return mix(c1, c2, smoothstep(0.0, 0.25, t));
    }
    if (t < 0.5) {
        return mix(c2, c3, smoothstep(0.25, 0.5, t));
    }
    if (t < 0.75) {
        return mix(c3, c4, smoothstep(0.5, 0.75, t));
    }
    return mix(c4, c5, smoothstep(0.75, 1.0, t));
}

[[ stitchable ]] half4 swPlasmaSolar(float2 position,
                                     half4  color,
                                     float4 boundingRect,
                                     float  time,
                                     half4  c1,
                                     half4  c2,
                                     half4  c3,
                                     half4  c4,
                                     half4  c5,
                                     float  scale,
                                     float  intensity,
                                     float  distortion) {
    float2 size = boundingRect.zw;
    float2 uv = position / size;
    float aspect = size.x / size.y;
    float2 p = uv - 0.5;
    p.x *= aspect;
    p *= scale;

    float v = 0.0;
    v += sin(p.x * 2.1 + time * 0.7);
    v += sin(p.y * 2.5 + time * 0.9);
    v += sin((p.x + p.y) * 1.4 + time * 0.5);
    v += swPlasmaFBM3(p * 2.0 + time * 0.18)
        * distortion * 2.0;
    v = (v + 4.0) * 0.125;
    v = clamp(v * intensity, 0.0, 1.0);

    float3 col = swPlasmaPal5(
        v,
        float3(c1.rgb),
        float3(c2.rgb),
        float3(c3.rgb),
        float3(c4.rgb),
        float3(c5.rgb)
    );
    col += pow(v, 4.0) * 0.4;
    return half4(half3(col), 1.0h);
}
