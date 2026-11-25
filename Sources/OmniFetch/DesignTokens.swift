import SwiftUI
import AppKit

// MARK: - Visual DNA Tokens (SSOT synced with .design/visual-dna.json)
//
// Strict <= 6 distinct colors per frame:
// 1. canvas     2. surface     3. ink (+ ink-alpha hairlines)
// 4. inkMuted   5. accent      6. danger (faults/destructive only)

enum OmniColor {
    static let canvas = dynamic(light: 0xF6F8F9, dark: 0x12171A)
    static let surface = dynamic(light: 0xEBF0F2, dark: 0x1B2227)
    static let ink = dynamic(light: 0x162026, dark: 0xE8EEF2)
    static let inkMuted = dynamic(light: 0x4F606A, dark: 0x8E9FA9)
    static let accent = dynamic(light: 0x0B6E77, dark: 0x3BBCC7)
    static let accentInk = dynamic(light: 0xF6F8F9, dark: 0x12171A)
    static let danger = dynamic(light: 0xB93827, dark: 0xEE7262)

    // Derived alpha ramps (same 6 hues, zero extra colors)
    static let line = dynamic(light: 0x162026, lightAlpha: 0.11, dark: 0xE8EEF2, darkAlpha: 0.10)
    static let lineStrong = dynamic(light: 0x162026, lightAlpha: 0.18, dark: 0xE8EEF2, darkAlpha: 0.17)
    static let hoverFill = dynamic(light: 0x162026, lightAlpha: 0.045, dark: 0xE8EEF2, darkAlpha: 0.055)
    static let activeFill = dynamic(light: 0x0B6E77, lightAlpha: 0.10, dark: 0x3BBCC7, darkAlpha: 0.13)
    static let accentLine = dynamic(light: 0x0B6E77, lightAlpha: 0.34, dark: 0x3BBCC7, darkAlpha: 0.38)
    static let dangerFill = dynamic(light: 0xB93827, lightAlpha: 0.10, dark: 0xEE7262, darkAlpha: 0.14)
    static let trackRail = dynamic(light: 0x162026, lightAlpha: 0.10, dark: 0xE8EEF2, darkAlpha: 0.11)

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1,
                                dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: alpha
            )
        })
    }
}

enum OmniRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let pill: CGFloat = 999
}

enum OmniSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum OmniFont {
    static let windowTitle = Font.system(size: 15, weight: .semibold)
    static let sheetTitle = Font.system(size: 16, weight: .semibold)
    static let rowTitle = Font.system(size: 13.5, weight: .medium)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let meta = Font.system(size: 11.5, weight: .regular)
    static let metaMedium = Font.system(size: 11.5, weight: .medium)
    static let telemetry = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let telemetrySmall = Font.system(size: 11.5, weight: .regular).monospacedDigit()
    static let badge = Font.system(size: 11, weight: .medium)
}

enum OmniMotion {
    static func snappy(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.24, dampingFraction: 0.96)
    }

    static func panel(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.28, dampingFraction: 0.94)
    }

    static let press: Animation = .easeOut(duration: 0.11)
    static let hover: Animation = .easeOut(duration: 0.13)
    static let progress: Animation = .easeOut(duration: 0.16)
}

// MARK: - Brand Mark Vector (matches App Icon 1:1)

struct OmniMarkView: View {
    var size: CGFloat = 20
    var arcColor: Color = OmniColor.accent
    var arrowColor: Color = OmniColor.ink
    var lineScale: CGFloat = 1.0

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height)
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let radius = s * 0.40
            let arcWidth = max(1.6, s * 0.112 * lineScale)
            let arrowWidth = max(1.5, s * 0.106 * lineScale)
            let span: CGFloat = 52 * .pi / 180

            var leftArc = Path()
            leftArc.addArc(center: center, radius: radius,
                           startAngle: .radians(.pi - span),
                           endAngle: .radians(.pi + span),
                           clockwise: false)
            var rightArc = Path()
            rightArc.addArc(center: center, radius: radius,
                            startAngle: .radians(-span),
                            endAngle: .radians(span),
                            clockwise: false)

            let arcStyle = StrokeStyle(lineWidth: arcWidth, lineCap: .round, lineJoin: .round)
            ctx.stroke(leftArc, with: .color(arcColor), style: arcStyle)
            ctx.stroke(rightArc, with: .color(arcColor), style: arcStyle)

            var arrow = Path()
            let topY = center.y - s * 0.36
            let apexY = center.y + s * 0.32
            let wingDX = s * 0.185
            arrow.move(to: CGPoint(x: center.x, y: topY))
            arrow.addLine(to: CGPoint(x: center.x, y: apexY - s * 0.02))
            arrow.move(to: CGPoint(x: center.x - wingDX, y: apexY - wingDX))
            arrow.addLine(to: CGPoint(x: center.x, y: apexY))
            arrow.addLine(to: CGPoint(x: center.x + wingDX, y: apexY - wingDX))

            let arrowStyle = StrokeStyle(lineWidth: arrowWidth, lineCap: .round, lineJoin: .round)
            ctx.stroke(arrow, with: .color(arrowColor), style: arrowStyle)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Tactile Button Styles (Zero-Latency Press Feedback)

enum OmniButtonVariant {
    case primary
    case secondary
    case subtle
    case destructive
}

struct OmniButtonStyle: ButtonStyle {
    var variant: OmniButtonVariant = .secondary
    var compact: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(compact ? OmniFont.metaMedium : OmniFont.bodyMedium)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 28 : 32)
            .foregroundStyle(foregroundColor)
            .background(backgroundView(pressed: pressed))
            .overlay(borderOverlay)
            .opacity(isEnabled ? (pressed ? 0.90 : 1.0) : 0.42)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1.0)
            .animation(OmniMotion.press, value: pressed)
            .animation(OmniMotion.hover, value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary: return OmniColor.accentInk
        case .secondary, .subtle: return OmniColor.ink
        case .destructive: return OmniColor.danger
        }
    }

    @ViewBuilder
    private func backgroundView(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? OmniRadius.sm : 8, style: .continuous)
        switch variant {
        case .primary:
            shape.fill(OmniColor.accent.opacity(isHovered ? 0.92 : 1.0))
        case .secondary:
            shape.fill(isHovered ? OmniColor.hoverFill : OmniColor.surface)
        case .subtle:
            shape.fill(isHovered || pressed ? OmniColor.hoverFill : .clear)
        case .destructive:
            shape.fill(isHovered ? OmniColor.dangerFill : OmniColor.surface)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? OmniRadius.sm : 8, style: .continuous)
        switch variant {
        case .primary, .subtle:
            EmptyView()
        case .secondary:
            shape.strokeBorder(isHovered ? OmniColor.lineStrong : OmniColor.line, lineWidth: 1)
        case .destructive:
            shape.strokeBorder(OmniColor.danger.opacity(0.32), lineWidth: 1)
        }
    }
}

struct OmniIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = OmniColor.ink
    var emphasized: Bool = false
    var size: CGFloat = 28
    var disabled: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size <= 26 ? 11 : 12, weight: .semibold))
                .foregroundStyle(emphasized ? OmniColor.accentInk : tint)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: OmniRadius.sm + 1, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OmniRadius.sm + 1, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(TactilePressStyle(reduceMotion: reduceMotion))
        .disabled(disabled)
        .opacity(disabled ? 0.36 : 1)
        .onHover { isHovered = $0 }
        .animation(OmniMotion.hover, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }

    private var backgroundColor: Color {
        if emphasized {
            return isHovered ? OmniColor.accent.opacity(0.88) : OmniColor.accent
        }
        return isHovered ? OmniColor.hoverFill : .clear
    }

    private var borderColor: Color {
        if emphasized { return .clear }
        return isHovered ? OmniColor.line : .clear
    }
}

struct TactilePressStyle: ButtonStyle {
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(OmniMotion.press, value: configuration.isPressed)
    }
}

// MARK: - GPU-Composited Throughput Bar (Zero Layout Thrash at 10Hz+)

struct ThroughputTrackView: View {
    let progress: Double
    let isActive: Bool
    let isIndeterminate: Bool
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: CGFloat {
        CGFloat(min(1, max(0, progress)))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(OmniColor.trackRail)

                if isIndeterminate {
                    indeterminateSweep(width: width)
                } else {
                    Capsule(style: .continuous)
                        .fill(isPaused ? OmniColor.inkMuted.opacity(0.55) : OmniColor.accent)
                        .frame(width: width)
                        .scaleEffect(x: max(0.015, clamped), y: 1, anchor: .leading)
                        .animation(reduceMotion ? nil : OmniMotion.progress, value: clamped)
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private func indeterminateSweep(width: CGFloat) -> some View {
        if reduceMotion {
            Capsule(style: .continuous)
                .fill(OmniColor.accent.opacity(0.65))
                .frame(width: width * 0.35)
                .offset(x: width * 0.325)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
                let period: Double = 1.25
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let barWidth = max(36, width * 0.28)
                let travel = width + barWidth
                let x = -barWidth + CGFloat(phase) * travel
                Capsule(style: .continuous)
                    .fill(OmniColor.accent)
                    .frame(width: barWidth)
                    .offset(x: x)
            }
        }
    }
}

// MARK: - Live Throughput Sparkline (Canvas, 0% CPU When Idle)

struct ThroughputSparklineView: View {
    let samples: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count >= 2 else { return }
            let peak = max(samples.max() ?? 0, 1024)
            guard peak > 0 else { return }

            let stepX = size.width / CGFloat(samples.count - 1)
            let h = size.height - 2

            var line = Path()
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * stepX
                let normalized = min(1, max(0, sample / peak))
                let y = size.height - 1 - CGFloat(normalized) * h
                if i == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            ctx.fill(area, with: .color(OmniColor.accent.opacity(0.14)))
            ctx.stroke(
                line,
                with: .color(OmniColor.accent),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 68, height: 16)
        .accessibilityHidden(true)
    }
}
