#!/usr/bin/env swift
// Renders the OmniFetch macOS app icon — "Optical Aperture Collimator".
//
// Twin symmetric Optical Signal Teal lens arcs frame a machined Mist-Silver
// downward fetch conduit, eliminating power-button ambiguity while reading
// crisply from 16px Finder lists to 1024px Dock previews.
//
// Usage:
//   swift make_icon.swift <iconset-dir>               # write all macOS iconset sizes
//   swift make_icon.swift --sheet <out.png>           # render variant & monochrome contact sheet
//   swift make_icon.swift --detail <out.png>          # pixel-truth 16/32/64/128 check
//   swift make_icon.swift <iconset-dir> --tone slate|mineral
import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Color Tokens (SSOT synced with .design/visual-dna.json)

struct IconPalette {
    let shellTop: UInt32
    let shellMid: UInt32
    let shellBottom: UInt32
    let chamberTop: UInt32
    let chamberBottom: UInt32
    let ringLight: UInt32
    let ringMid: UInt32
    let ringDeep: UInt32
    let arrowTop: UInt32
    let arrowBottom: UInt32
    let tickHex: UInt32
    let tickAlpha: CGFloat
    let rimTopAlpha: CGFloat
    let rimBottomHex: UInt32
    let rimBottomAlpha: CGFloat
    let glyphShadowAlpha: CGFloat
    let tileShadowAlpha: CGFloat
    let isLightShell: Bool
}

enum Tone: String, CaseIterable {
    case slate    // Default: anodized optical slate + optical signal teal + mist silver
    case mineral  // Light optical ceramic mineral + deep signal teal + slate ink

    var palette: IconPalette {
        switch self {
        case .slate:
            return IconPalette(
                shellTop: 0x242F37,
                shellMid: 0x161D23,
                shellBottom: 0x0C1115,
                chamberTop: 0x080C0F,
                chamberBottom: 0x182129,
                ringLight: 0x4ED2DD,
                ringMid: 0x1E9BA7,
                ringDeep: 0x0C6873,
                arrowTop: 0xF5F9FB,
                arrowBottom: 0xC6D3DC,
                tickHex: 0x8E9FA9,
                tickAlpha: 0.22,
                rimTopAlpha: 0.24,
                rimBottomHex: 0x000000,
                rimBottomAlpha: 0.42,
                glyphShadowAlpha: 0.52,
                tileShadowAlpha: 0.34,
                isLightShell: false
            )
        case .mineral:
            return IconPalette(
                shellTop: 0xF9FBFC,
                shellMid: 0xEEF3F5,
                shellBottom: 0xDFE7EB,
                chamberTop: 0xDCE4E9,
                chamberBottom: 0xF4F8FA,
                ringLight: 0x15909B,
                ringMid: 0x0C747E,
                ringDeep: 0x08545C,
                arrowTop: 0x1D2B33,
                arrowBottom: 0x10181D,
                tickHex: 0x4F606A,
                tickAlpha: 0.22,
                rimTopAlpha: 0.85,
                rimBottomHex: 0x162026,
                rimBottomAlpha: 0.14,
                glyphShadowAlpha: 0.16,
                tileShadowAlpha: 0.22,
                isLightShell: true
            )
        }
    }
}

enum RenderMode: String {
    case standard
    case monoLight
    case monoDark
}

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Continuous macOS Squircle Geometry

func tileInset(_ size: CGFloat) -> CGFloat {
    if size <= 16 { return 0.042 }
    if size <= 32 { return 0.056 }
    return 100.0 / 1024.0
}

func squirclePath(_ size: CGFloat, insetFraction: CGFloat? = nil, extraInset: CGFloat = 0) -> CGPath {
    let inset = size * (insetFraction ?? tileInset(size)) + extraInset
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = rect.width * 0.2237
    return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .path(in: rect)
        .cgPath
}

// MARK: - Optical Aperture Collimator Geometry

struct MarkMetrics {
    let center: CGPoint
    let ringRadius: CGFloat
    let ringStroke: CGFloat
    let arcHalfSpan: CGFloat    // radians above/below the horizontal axis on left & right
    let shaftTopY: CGFloat
    let shaftBottomY: CGFloat
    let chevronApexY: CGFloat
    let chevronWingDX: CGFloat
    let chevronWingY: CGFloat
    let arrowStroke: CGFloat
}

func metrics(for s: CGFloat) -> MarkMetrics {
    let small16 = s <= 16
    let small32 = s <= 32 && !small16
    let scale: CGFloat = small16 ? 1.08 : (small32 ? 1.04 : 1.0)

    let cx: CGFloat = s * 0.500
    let cy: CGFloat = s * 0.500

    let ringRadius = s * 0.252 * scale
    let ringStroke = s * (small16 ? 0.092 : (small32 ? 0.080 : 0.070))
    let arrowStroke = s * (small16 ? 0.088 : (small32 ? 0.076 : 0.066))
    // Each side arc sweeps 104deg centered on 0deg / 180deg (open 76deg at 12 and 6 o'clock)
    let arcHalfSpan: CGFloat = (small16 ? 49.0 : (small32 ? 50.5 : 52.0)) * .pi / 180.0

    let shaftTopY = cy + s * 0.238 * scale
    let chevronApexY = cy - s * 0.204 * scale
    let shaftBottomY = chevronApexY + s * 0.012 * scale
    let chevronWingDX = s * 0.120 * scale
    let chevronWingY = chevronApexY + chevronWingDX

    return MarkMetrics(
        center: CGPoint(x: cx, y: cy),
        ringRadius: ringRadius,
        ringStroke: ringStroke,
        arcHalfSpan: arcHalfSpan,
        shaftTopY: shaftTopY,
        shaftBottomY: shaftBottomY,
        chevronApexY: chevronApexY,
        chevronWingDX: chevronWingDX,
        chevronWingY: chevronWingY,
        arrowStroke: arrowStroke
    )
}

func leftArcPath(_ m: MarkMetrics) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: m.center, radius: m.ringRadius,
                startAngle: .pi - m.arcHalfSpan,
                endAngle: .pi + m.arcHalfSpan,
                clockwise: false)
    return path
}

func rightArcPath(_ m: MarkMetrics) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: m.center, radius: m.ringRadius,
                startAngle: -m.arcHalfSpan,
                endAngle: m.arcHalfSpan,
                clockwise: false)
    return path
}

func arrowShaftPath(_ m: MarkMetrics) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: m.center.x, y: m.shaftTopY))
    path.addLine(to: CGPoint(x: m.center.x, y: m.shaftBottomY))
    return path
}

func arrowChevronPath(_ m: MarkMetrics) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: m.center.x - m.chevronWingDX, y: m.chevronWingY))
    path.addLine(to: CGPoint(x: m.center.x, y: m.chevronApexY))
    path.addLine(to: CGPoint(x: m.center.x + m.chevronWingDX, y: m.chevronWingY))
    return path
}

// MARK: - Core Rendering

func drawIcon(_ ctx: CGContext, size s: CGFloat, tone: Tone, mode: RenderMode = .standard) {
    ctx.saveGState()
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    if mode != .standard {
        drawMonochromeMark(ctx, size: s, onDark: mode == .monoDark)
        ctx.restoreGState()
        return
    }

    let pal = tone.palette
    let shell = squirclePath(s)
    let m = metrics(for: s)

    // 1. Grounded Dock contact shadow
    if s >= 32 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014),
                      blur: s * 0.028,
                      color: rgba(0x05090C, pal.tileShadowAlpha))
        ctx.addPath(shell)
        ctx.setFillColor(rgba(pal.shellBottom))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Anodized shell clipped to continuous squircle
    ctx.saveGState()
    ctx.addPath(shell)
    ctx.clip()

    if let bg = CGGradient(
        colorsSpace: srgbSpace,
        colors: [rgba(pal.shellTop), rgba(pal.shellMid), rgba(pal.shellBottom)] as CFArray,
        locations: [0.0, 0.48, 1.0]
    ) {
        ctx.drawLinearGradient(
            bg,
            start: CGPoint(x: s * 0.5, y: s * (1.0 - tileInset(s))),
            end: CGPoint(x: s * 0.5, y: s * tileInset(s)),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Subtle overhead studio sheen
    if s >= 64, let sheen = CGGradient(
        colorsSpace: srgbSpace,
        colors: [rgba(0xFFFFFF, pal.isLightShell ? 0.55 : 0.085), rgba(0xFFFFFF, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: s * 0.5, y: s * 0.90), startRadius: 0,
            endCenter: CGPoint(x: s * 0.5, y: s * 0.88), endRadius: s * 0.52,
            options: []
        )
    }

    // 3. Milled recessed optical lens chamber (>= 64px)
    if s >= 64 {
        let chamberRadius = s * 0.336
        let chamberRect = CGRect(
            x: m.center.x - chamberRadius,
            y: m.center.y - chamberRadius,
            width: chamberRadius * 2,
            height: chamberRadius * 2
        )

        ctx.saveGState()
        ctx.addEllipse(in: chamberRect)
        ctx.clip()
        if let cg = CGGradient(
            colorsSpace: srgbSpace,
            colors: [rgba(pal.chamberTop), rgba(pal.chamberBottom)] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                cg,
                start: CGPoint(x: m.center.x, y: m.center.y + chamberRadius),
                end: CGPoint(x: m.center.x, y: m.center.y - chamberRadius),
                options: []
            )
        }

        // Inner top-lip ambient occlusion shadow
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -s * 0.004)
        ctx.addEllipse(in: chamberRect)
        ctx.setStrokeColor(rgba(0x000000, pal.isLightShell ? 0.08 : 0.45))
        ctx.setLineWidth(s * 0.008)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.restoreGState()

        // Lower-rim specular catchlight along the bottom of the milled dish
        ctx.saveGState()
        let lipPath = CGMutablePath()
        lipPath.addArc(center: m.center, radius: chamberRadius,
                       startAngle: CGFloat.pi * 1.12, endAngle: CGFloat.pi * 1.88, clockwise: false)
        ctx.addPath(lipPath)
        ctx.setStrokeColor(rgba(0xE8EEF2, pal.isLightShell ? 0.72 : 0.09))
        ctx.setLineWidth(max(1.0, s * 0.003))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 4. Subtle precision optical ticks on left/right lens bezel (>= 256px)
    if s >= 256 {
        ctx.saveGState()
        ctx.setStrokeColor(rgba(pal.tickHex, pal.tickAlpha))
        ctx.setLineCap(.round)
        let innerR = s * 0.305
        let outerR = s * 0.320
        // Ticks only along the optical arcs (0, +-30, +-60, 180, 150, 210, 120, 240 — skipping 90 and 270 portals)
        for i in 0..<12 {
            let deg = Double(i) * 30.0
            if deg == 90.0 || deg == 270.0 { continue }
            let rad = CGFloat(deg * .pi / 180.0)
            let isEquator = (deg == 0.0 || deg == 180.0)
            ctx.setLineWidth(s * (isEquator ? 0.0055 : 0.0032))
            let r0 = isEquator ? innerR - s * 0.004 : innerR
            ctx.move(to: CGPoint(x: m.center.x + cos(rad) * r0, y: m.center.y + sin(rad) * r0))
            ctx.addLine(to: CGPoint(x: m.center.x + cos(rad) * outerR, y: m.center.y + sin(rad) * outerR))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // 5. Twin Symmetric Optical Signal Teal Collimator Arcs
    let leftFilled = leftArcPath(m).copy(
        strokingWithWidth: m.ringStroke,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4
    )
    let rightFilled = rightArcPath(m).copy(
        strokingWithWidth: m.ringStroke,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4
    )

    for arcFilled in [leftFilled, rightFilled] {
        if s >= 64 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                          blur: s * 0.024,
                          color: rgba(0x04080B, pal.glyphShadowAlpha))
            ctx.addPath(arcFilled)
            ctx.setFillColor(rgba(pal.ringDeep))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(arcFilled)
        ctx.clip()
        if let rg = CGGradient(
            colorsSpace: srgbSpace,
            colors: [rgba(pal.ringLight), rgba(pal.ringMid), rgba(pal.ringDeep)] as CFArray,
            locations: [0.0, 0.50, 1.0]
        ) {
            ctx.drawLinearGradient(
                rg,
                start: CGPoint(x: m.center.x, y: m.center.y + m.ringRadius + m.ringStroke * 0.4),
                end: CGPoint(x: m.center.x, y: m.center.y - m.ringRadius - m.ringStroke * 0.4),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Top-bevel specular edge: shifting the stroked silhouette slightly DOWN (-Y in CG)
        // inside the clipped arc exposes only the upper rim to the 12-o'clock studio light.
        if s >= 128 {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: -s * 0.0035)
            ctx.addPath(arcFilled)
            ctx.setStrokeColor(rgba(0xCCF8FC, pal.isLightShell ? 0.22 : 0.26))
            ctx.setLineWidth(s * 0.0045)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // 6. Machined Mist-Silver Plunge Arrow
    let shaftFilled = arrowShaftPath(m).copy(
        strokingWithWidth: m.arrowStroke,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4
    )
    let chevronFilled = arrowChevronPath(m).copy(
        strokingWithWidth: m.arrowStroke,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4
    )

    let arrowUnion = shaftFilled.union(chevronFilled)

    ctx.saveGState()
    if s >= 64 {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.013),
                      blur: s * 0.024,
                      color: rgba(0x04080B, pal.glyphShadowAlpha))
        ctx.addPath(arrowUnion)
        ctx.setFillColor(rgba(pal.arrowBottom))
        ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(arrowUnion)
    ctx.clip()
    if let ag = CGGradient(
        colorsSpace: srgbSpace,
        colors: [rgba(pal.arrowTop), rgba(pal.arrowBottom)] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            ag,
            start: CGPoint(x: m.center.x, y: m.shaftTopY + m.arrowStroke * 0.5),
            end: CGPoint(x: m.center.x, y: m.chevronApexY - m.arrowStroke * 0.5),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    if s >= 128 && !pal.isLightShell {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -s * 0.0028)
        ctx.addPath(arrowUnion)
        ctx.setStrokeColor(rgba(0xFFFFFF, 0.40))
        ctx.setLineWidth(s * 0.004)
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // 7. Continuous squircle machined inner bezel rim
    let innerRim = squirclePath(s, extraInset: max(0.5, s * 0.0022))
    ctx.saveGState()
    ctx.addPath(innerRim)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if let rimGrad = CGGradient(
        colorsSpace: srgbSpace,
        colors: [
            rgba(0xFFFFFF, pal.rimTopAlpha),
            rgba(0xFFFFFF, pal.rimTopAlpha * 0.16),
            rgba(pal.rimBottomHex, pal.rimBottomAlpha)
        ] as CFArray,
        locations: [0.0, 0.32, 1.0]
    ) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: s * 0.5, y: s * (1.0 - tileInset(s))),
            end: CGPoint(x: s * 0.5, y: s * tileInset(s)),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState() // end shell clip
    ctx.restoreGState()
}

private func drawMonochromeMark(_ ctx: CGContext, size s: CGFloat, onDark: Bool) {
    let m = metrics(for: s)
    let ink = onDark ? rgba(0xE8EEF2) : rgba(0x162026)
    ctx.setStrokeColor(ink)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.setLineWidth(m.ringStroke)
    ctx.addPath(leftArcPath(m))
    ctx.strokePath()
    ctx.addPath(rightArcPath(m))
    ctx.strokePath()

    ctx.setLineWidth(m.arrowStroke)
    ctx.addPath(arrowShaftPath(m))
    ctx.strokePath()
    ctx.addPath(arrowChevronPath(m))
    ctx.strokePath()
}

// MARK: - PNG & Contact Sheet Output

func renderPNG(size: Int, tone: Tone, mode: RenderMode = .standard) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    drawIcon(gc.cgContext, size: CGFloat(size), tone: tone, mode: mode)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func renderImage(size: CGFloat, tone: Tone, mode: RenderMode = .standard) -> NSImage {
    let data = renderPNG(size: Int(size), tone: tone, mode: mode)
    return NSImage(data: data) ?? NSImage(size: NSSize(width: size, height: size))
}

let arguments = CommandLine.arguments

func value(for flag: String, default fallback: String) -> String {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return fallback }
    return arguments[index + 1]
}

let tone = Tone(rawValue: value(for: "--tone", default: "slate")) ?? .slate
let outputDirectory = arguments.dropFirst().first {
    !$0.hasPrefix("--") && $0 != tone.rawValue
} ?? "./AppIcon.iconset"

if let detailIndex = arguments.firstIndex(of: "--detail"), arguments.count > detailIndex + 1 {
    let outputPath = arguments[detailIndex + 1]
    let sizes = [16, 32, 64, 128]
    let scale = 6
    let gap = 36
    let width = sizes.reduce(0) { $0 + $1 * scale + gap } + gap
    let height = 128 * scale + gap * 2 + 24
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.interpolationQuality = .none
    ctx.setFillColor(rgba(0x1B2227))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    var x = CGFloat(gap)
    for sz in sizes {
        let img = renderImage(size: CGFloat(sz), tone: tone)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let drawW = CGFloat(sz * scale)
        ctx.draw(cg, in: CGRect(x: x, y: CGFloat(gap + 24), width: drawW, height: drawW))
        let label = "\(sz)px" as NSString
        label.draw(
            at: NSPoint(x: x, y: CGFloat(gap)),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedRed: 0.85, green: 0.90, blue: 0.93, alpha: 0.85)
            ]
        )
        x += drawW + CGFloat(gap)
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
    print("wrote detail \(outputPath) [\(tone.rawValue)]")
    exit(0)
}

if let sheetIndex = arguments.firstIndex(of: "--sheet"), arguments.count > sheetIndex + 1 {
    let outputPath = arguments[sheetIndex + 1]
    let cell: CGFloat = 300
    let gap: CGFloat = 32
    let cols = 2
    let rows = 2
    let width = CGFloat(cols) * cell + CGFloat(cols + 1) * gap
    let height = CGFloat(rows) * cell + CGFloat(rows + 1) * gap

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.setFillColor(rgba(0x12171A))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let cards: [(label: String, bgHex: UInt32, labelDark: Bool, tone: Tone, mode: RenderMode)] = [
        ("slate on light dock", 0xECEFF2, true, .slate, .standard),
        ("slate on dark dock", 0x1C2227, false, .slate, .standard),
        ("mineral variant", 0x1C2227, false, .mineral, .standard),
        ("monochrome silhouette", 0xF6F8F9, true, .slate, .monoLight)
    ]

    for (index, card) in cards.enumerated() {
        let col = index % cols
        let row = index / cols
        let x = gap + CGFloat(col) * (cell + gap)
        let y = height - gap - CGFloat(row + 1) * cell - CGFloat(row) * gap
        let rect = CGRect(x: x, y: y, width: cell, height: cell)
        let cardPath = RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: rect).cgPath
        ctx.addPath(cardPath)
        ctx.setFillColor(rgba(card.bgHex))
        ctx.fillPath()

        let iconSize: CGFloat = 216
        let img = renderImage(size: iconSize * 2, tone: card.tone, mode: card.mode)
        img.draw(in: NSRect(x: x + (cell - iconSize) / 2, y: y + (cell - iconSize) / 2 + 10, width: iconSize, height: iconSize))

        let labelColor = card.labelDark
            ? NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 0.78)
            : NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.95, alpha: 0.78)
        (card.label as NSString).draw(
            at: NSPoint(x: x + 16, y: y + 14),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: labelColor
            ]
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
    print("wrote sheet \(outputPath)")
    exit(0)
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let data = renderPNG(size: variant.pixels, tone: tone)
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(variant.name).png")
    try data.write(to: url)
}
print("wrote \(variants.count) icon sizes to \(outputDirectory) [\(tone.rawValue)]")
