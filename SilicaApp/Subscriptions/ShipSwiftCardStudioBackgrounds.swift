//
//  ShipSwiftCardStudioBackgrounds.swift
//  Silica
//
//  Card-studio adaptations of ShipSwift's AnimatedMeshGradient, Star Nest,
//  and Plasma backgrounds.
//  Source: https://github.com/signerlabs/ShipSwift
//

import SwiftUI

struct SWCardStudioAnimatedMeshGradient: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let paletteA: [Color] = [
        .indigo.opacity(0.9), .blue.opacity(0.85), .cyan.opacity(0.8),
        .blue.opacity(0.85), .indigo.opacity(0.9), .blue.opacity(0.85),
        .cyan.opacity(0.8), .blue.opacity(0.85), .indigo.opacity(0.9),
    ]

    private let paletteB: [Color] = [
        .cyan.opacity(0.8), .indigo.opacity(0.9), .blue.opacity(0.85),
        .indigo.opacity(0.85), .blue.opacity(0.9), .cyan.opacity(0.85),
        .blue.opacity(0.85), .cyan.opacity(0.8), .indigo.opacity(0.9),
    ]

    var body: some View {
        if #available(iOS 18.0, *) {
            if reduceMotion {
                meshGradient(colors: paletteA)
            } else {
                SWCardStudioAnimatedMeshLayer(
                    paletteA: paletteA,
                    paletteB: paletteB
                )
            }
        } else {
            LinearGradient(
                colors: [.indigo, .blue, .cyan],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @available(iOS 18.0, *)
    private func meshGradient(colors: [Color]) -> some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1),
            ],
            colors: colors
        )
    }
}

@available(iOS 18.0, *)
private struct SWCardStudioAnimatedMeshLayer: View {
    let paletteA: [Color]
    let paletteB: [Color]

    @State private var appear = false

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1),
            ],
            colors: appear ? paletteA : paletteB
        )
        .onAppear {
            withAnimation(
                .easeInOut(duration: 5)
                    .repeatForever(autoreverses: true)
            ) {
                appear = true
            }
        }
    }
}

struct SWCardStudioStarNest: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        if reduceMotion {
            rendered(time: 0)
        } else {
            TimelineView(.animation) { context in
                rendered(
                    time: Float(context.date.timeIntervalSince(start))
                )
            }
        }
    }

    private func rendered(time: Float) -> some View {
        Color.black
            .colorEffect(
                Shader(
                    function: ShaderFunction(
                        library: .default,
                        name: "swStarNest"
                    ),
                    arguments: [
                        .boundingRect,
                        .float(time),
                        .float(0.01),
                        .float(0.8),
                        .float(0.0015),
                        .float(0.85),
                        .float(0.3),
                        .float(0.73),
                        .float(0.5),
                        .float(0.8),
                        .float(16),
                        .float(17),
                    ]
                )
            )
    }
}

struct SWCardStudioPlasma: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    private let palette: [Color] = [
        Color(red: 0.102, green: 0.020, blue: 0),
        Color(red: 0.353, green: 0.071, blue: 0.031),
        Color(red: 0.769, green: 0.290, blue: 0.125),
        Color(red: 0.941, green: 0.541, blue: 0.227),
        Color(red: 1, green: 0.773, blue: 0.478),
    ]

    var body: some View {
        if reduceMotion {
            rendered(time: 0)
        } else {
            TimelineView(.animation) { context in
                rendered(
                    time: Float(context.date.timeIntervalSince(start))
                )
            }
        }
    }

    private func rendered(time: Float) -> some View {
        palette[2]
            .colorEffect(
                Shader(
                    function: ShaderFunction(
                        library: .default,
                        name: "swPlasmaSolar"
                    ),
                    arguments: [
                        .boundingRect,
                        .float(time),
                        .color(palette[0]),
                        .color(palette[1]),
                        .color(palette[2]),
                        .color(palette[3]),
                        .color(palette[4]),
                        .float(1),
                        .float(1),
                        .float(1),
                    ]
                )
            )
    }
}
