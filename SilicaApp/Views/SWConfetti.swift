//
//  SWConfetti.swift
//  Silica
//
//  Adapted from ShipSwift's SWConfetti.swift.
//  Source: https://github.com/signerlabs/ShipSwift
//  License: MIT
//

import SwiftUI

struct SWConfetti<Content: View>: View {
    @Binding var isActive: Bool
    var particleCount: Int = 80
    var colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
    var shapes: [SWConfettiShape] = SWConfettiShape.allCases
    var duration: Double = 3.0
    var gravity: Double = 500
    var autoReset: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .overlay {
                SWConfettiCanvas(
                    isActive: $isActive,
                    particleCount: particleCount,
                    colors: colors,
                    shapes: shapes,
                    duration: duration,
                    gravity: gravity,
                    autoReset: autoReset
                )
                .allowsHitTesting(false)
            }
    }
}

enum SWConfettiShape: CaseIterable {
    case rectangle
    case circle
    case triangle
    case strip
}

private struct SWConfettiParticle {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var angle: Double
    var angularVelocity: Double
    var scaleX: Double
    var wobbleSpeed: Double
    var wobblePhase: Double
    let color: Color
    let shape: SWConfettiShape
    let width: Double
    let height: Double
}

private struct SWConfettiCanvas: View {
    @Binding var isActive: Bool
    let particleCount: Int
    let colors: [Color]
    let shapes: [SWConfettiShape]
    let duration: Double
    let gravity: Double
    let autoReset: Bool

    @State private var particles: [SWConfettiParticle] = []
    @State private var startTime: Date?

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { gc, size in
                guard let start = startTime else { return }
                let elapsed = ctx.date.timeIntervalSince(start)
                if elapsed > duration { return }

                let progress = elapsed / duration
                let opacity = progress < 0.7 ? 1.0 : max(0, 1 - (progress - 0.7) / 0.3)

                for p in particles {
                    let t = elapsed
                    let px = size.width / 2 + p.x + p.vx * t
                    let py = size.height + p.y + p.vy * t + 0.5 * gravity * t * t
                    let angle = Angle.degrees(p.angle + p.angularVelocity * t)
                    let wobble = cos(p.wobbleSpeed * t + p.wobblePhase)
                    let currentScaleX = p.scaleX * wobble
                    guard abs(currentScaleX) > 0.001 else { continue }

                    guard px > -50 && px < size.width + 50 else { continue }
                    guard py > -50 && py < size.height + 200 else { continue }

                    gc.opacity = opacity
                    gc.translateBy(x: px, y: py)
                    gc.rotate(by: angle)
                    gc.scaleBy(x: currentScaleX, y: 1.0)

                    let rect = CGRect(
                        x: -p.width / 2,
                        y: -p.height / 2,
                        width: p.width,
                        height: p.height
                    )

                    switch p.shape {
                    case .rectangle:
                        gc.fill(Path(rect), with: .color(p.color))
                    case .circle:
                        gc.fill(Path(ellipseIn: rect), with: .color(p.color))
                    case .triangle:
                        var tri = Path()
                        tri.move(to: CGPoint(x: 0, y: -p.height / 2))
                        tri.addLine(to: CGPoint(x: p.width / 2, y: p.height / 2))
                        tri.addLine(to: CGPoint(x: -p.width / 2, y: p.height / 2))
                        tri.closeSubpath()
                        gc.fill(tri, with: .color(p.color))
                    case .strip:
                        let stripRect = CGRect(
                            x: -p.width / 2,
                            y: -p.height / 2,
                            width: p.width,
                            height: p.height
                        )
                        gc.fill(
                            Path(roundedRect: stripRect, cornerRadius: p.width / 2),
                            with: .color(p.color)
                        )
                    }

                    gc.scaleBy(x: 1.0 / currentScaleX, y: 1.0)
                    gc.rotate(by: .zero - angle)
                    gc.translateBy(x: -px, y: -py)
                    gc.opacity = 1.0
                }
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                spawnBurst()
            }
        }
        .task {
            if isActive {
                spawnBurst()
            }
        }
    }

    private func spawnBurst() {
        guard !colors.isEmpty, !shapes.isEmpty else { return }

        var newParticles: [SWConfettiParticle] = []
        newParticles.reserveCapacity(particleCount)

        for _ in 0..<particleCount {
            let halfAngle = Double.pi / 2
            let angle = -.pi / 2 + Double.random(in: -halfAngle...halfAngle)
            let speed = Double.random(in: 400...900)
            let vx = cos(angle) * speed
            let vy = sin(angle) * speed

            let shape = shapes.randomElement()!
            let isStrip = shape == .strip
            let w = isStrip ? Double.random(in: 3...5) : Double.random(in: 6...12)
            let h = isStrip ? Double.random(in: 14...28) : Double.random(in: 6...12)

            newParticles.append(SWConfettiParticle(
                x: Double.random(in: -20...20),
                y: 0,
                vx: vx,
                vy: vy,
                angle: Double.random(in: 0...360),
                angularVelocity: Double.random(in: -400...400),
                scaleX: Double.random(in: 0.6...1.0),
                wobbleSpeed: Double.random(in: 4...10),
                wobblePhase: Double.random(in: 0...(.pi * 2)),
                color: colors.randomElement()!,
                shape: shape,
                width: w,
                height: h
            ))
        }

        particles = newParticles
        startTime = .now

        if autoReset {
            Task {
                try? await Task.sleep(for: .seconds(duration))
                isActive = false
            }
        }
    }
}
