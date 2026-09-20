//
//  SilicaPolishedAluminum.metal
//  Silica
//
//  Adapted from ShipSwift's SWPolishedAluminum, itself adapted from ShaderKit.
//  ShipSwift copyright (c) 2026 SignerLabs.
//  ShaderKit copyright (c) 2025 James Rochabrun.
//  Licensed under the MIT License. See THIRD_PARTY_NOTICES.md.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float silicaAluminumHash(float2 position) {
    float3 value = fract(float3(position.xyx) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

static float silicaAluminumNoise(float2 position) {
    float2 integerPart = floor(position);
    float2 fractionalPart = fract(position);

    float topLeft = silicaAluminumHash(integerPart);
    float topRight = silicaAluminumHash(integerPart + float2(1.0, 0.0));
    float bottomLeft = silicaAluminumHash(integerPart + float2(0.0, 1.0));
    float bottomRight = silicaAluminumHash(integerPart + float2(1.0, 1.0));
    float2 curve = fractionalPart * fractionalPart * (3.0 - 2.0 * fractionalPart);

    return mix(topLeft, topRight, curve.x)
        + (bottomLeft - topLeft) * curve.y * (1.0 - curve.x)
        + (bottomRight - topRight) * curve.x * curve.y;
}

static half3 silicaAluminumRainbow(float progress) {
    half3 colors[7] = {
        half3(1.0h, 0.0h, 0.0h),
        half3(1.0h, 0.5h, 0.0h),
        half3(1.0h, 1.0h, 0.0h),
        half3(0.0h, 1.0h, 0.0h),
        half3(0.0h, 0.5h, 1.0h),
        half3(0.3h, 0.0h, 1.0h),
        half3(0.5h, 0.0h, 0.5h)
    };

    float scaledProgress = fract(progress) * 6.0;
    int index = int(scaledProgress);
    int nextIndex = (index + 1) % 7;
    return mix(colors[index], colors[nextIndex], half(fract(scaledProgress)));
}

static half3 silicaAluminumScreen(half3 base, half3 blend) {
    return 1.0h - (1.0h - base) * (1.0h - blend);
}

[[stitchable]] half4 silicaPolishedAluminum(
    float2 position,
    SwiftUI::Layer layer,
    float4 boundingRect,
    float2 tilt,
    float time,
    float intensity
) {
    float2 size = boundingRect.zw;
    float2 uv = position / size;
    half4 originalColor = layer.sample(position);

    if (originalColor.a < 0.01h) {
        return originalColor;
    }

    half3 silver = half3(0.92h, 0.93h, 0.95h);
    half3 darkSilver = half3(0.70h, 0.72h, 0.75h);
    half3 cyan = half3(0.50h, 0.85h, 0.92h);
    half3 purple = half3(0.78h, 0.65h, 0.88h);

    float gradientProgress = fract(uv.y + tilt.x * 0.4 + tilt.y * 0.3);
    half3 metalBase;

    if (gradientProgress < 0.2) {
        float progress = gradientProgress / 0.2;
        metalBase = mix(cyan, silver, half(smoothstep(0.0, 1.0, progress)));
    } else if (gradientProgress < 0.4) {
        float progress = (gradientProgress - 0.2) / 0.2;
        metalBase = mix(silver, half3(0.98h), half(smoothstep(0.0, 1.0, progress) * 0.5));
    } else if (gradientProgress < 0.6) {
        float progress = (gradientProgress - 0.4) / 0.2;
        metalBase = mix(silver, purple, half(smoothstep(0.0, 1.0, progress)));
    } else if (gradientProgress < 0.8) {
        float progress = (gradientProgress - 0.6) / 0.2;
        metalBase = mix(purple, darkSilver, half(smoothstep(0.0, 1.0, progress)));
    } else {
        float progress = (gradientProgress - 0.8) / 0.2;
        metalBase = mix(darkSilver, cyan, half(smoothstep(0.0, 1.0, progress)));
    }

    float horizontalVariation = sin(uv.x * 3.14159 + tilt.x * 2.0) * 0.5 + 0.5;
    metalBase = mix(metalBase, metalBase * 1.1h, half(horizontalVariation * 0.15));

    float noise = silicaAluminumNoise(uv * 80.0 + tilt * 2.0);
    metalBase += half3((noise - 0.5) * 0.08h);

    float rainbowAngle = 45.0 * 3.14159 / 180.0;
    float2 rainbowDirection = float2(cos(rainbowAngle), sin(rainbowAngle));
    float rainbowProgress = dot(uv + tilt * 0.5, rainbowDirection);
    float bandCenter = 0.5 + (tilt.x + tilt.y) * 0.25;
    float bandWidth = 0.3;
    float bandFalloff =
        smoothstep(bandCenter - bandWidth, bandCenter, rainbowProgress)
        * smoothstep(bandCenter + bandWidth, bandCenter, rainbowProgress);

    float rainbowPhase = rainbowProgress * 2.5 + (tilt.x - tilt.y) * 1.5;
    half3 rainbow = silicaAluminumRainbow(rainbowPhase);
    half3 result = silicaAluminumScreen(
        metalBase,
        rainbow * half(bandFalloff * intensity * 0.5)
    );

    float2 lightPosition = float2(0.5 + tilt.x * 0.3, 0.5 + tilt.y * 0.3);
    float specular = smoothstep(0.5, 0.0, length(uv - lightPosition));
    result += half3(half(pow(specular, 3.0) * 0.2));
    result = mix(originalColor.rgb, result, half(intensity));

    // Fine, card-fixed grain adds a restrained tactile finish without dirtying bright type.
    float fineGrain = silicaAluminumHash(floor(position * 1.35));
    float softGrain = silicaAluminumNoise(position * 0.22);
    float surfaceGrain = mix(softGrain, fineGrain, 0.72);
    half originalLuminance = dot(
        originalColor.rgb,
        half3(0.2126h, 0.7152h, 0.0722h)
    );
    half surfaceMask = 1.0h - smoothstep(0.78h, 0.96h, originalLuminance);
    result += half3(half((surfaceGrain - 0.5) * 0.016) * surfaceMask);

    return half4(clamp(result, half3(0.0h), half3(1.0h)), originalColor.a);
}
