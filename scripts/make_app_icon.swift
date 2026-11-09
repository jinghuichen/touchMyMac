#!/usr/bin/env swift
// Draws the TouchMyMac app icon with Core Graphics and writes every size the
// macOS AppIcon set needs. Run from the repo root:
//   swift scripts/make_app_icon.swift TouchMyMac/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let design: CGFloat = 1024
/// Core Graphics shadows ignore the CTM, so shadow sizes are scaled by hand.
var shadowScale: CGFloat = 1

func shadow(_ ctx: CGContext, dx: CGFloat, dy: CGFloat, blur: CGFloat, color: CGColor) {
    ctx.setShadow(offset: CGSize(width: dx * shadowScale, height: dy * shadowScale), blur: blur * shadowScale, color: color)
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

/// Apple-style continuous-corner rounded rectangle (the macOS icon tile shape).
func squircle(_ rect: CGRect, radius: CGFloat = 185.4) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let p = CGMutablePath()
    // Each corner: its point, the direction back along the incoming edge, and along the outgoing edge.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    for (i, (c, u, v)) in corners.enumerated() {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (u.dx * x + v.dx * y) * r, y: c.y + (u.dy * x + v.dy * y) * r)
        }
        i == 0 ? p.move(to: pt(1.52866483, 0)) : p.addLine(to: pt(1.52866483, 0))
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491176, 0.63149399), control1: pt(0.37282392, 0.16905899), control2: pt(0.16906013, 0.37282401))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0, 0.86840701), control2: pt(0, 1.08849299))
    }
    p.closeSubpath()
    return p
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func capsule(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: a)
    p.addLine(to: b)
    return p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
}

/// A pointing hand seen from the back, fingertip at the origin, finger pointing toward -y.
func handParts() -> (silhouette: CGPath, creases: CGPath, nail: CGPath) {
    var shape = capsule(from: CGPoint(x: 0, y: 52), to: CGPoint(x: 0, y: 330), width: 104)
    let parts: [CGPath] = [
        rounded(CGRect(x: -58, y: 250, width: 306, height: 360), 120),
        capsule(from: CGPoint(x: 92, y: 262), to: CGPoint(x: 92, y: 380), width: 82),
        capsule(from: CGPoint(x: 168, y: 280), to: CGPoint(x: 168, y: 390), width: 76),
        capsule(from: CGPoint(x: 236, y: 306), to: CGPoint(x: 236, y: 400), width: 66),
        // Thumb lying along the side of the index finger.
        capsule(from: CGPoint(x: -40, y: 470), to: CGPoint(x: -76, y: 330), width: 84),
    ]
    for part in parts { shape = shape.union(part) }

    let creases = CGMutablePath()
    // Gaps between the folded fingers.
    creases.move(to: CGPoint(x: 52, y: 272)); creases.addLine(to: CGPoint(x: 52, y: 336))
    creases.move(to: CGPoint(x: 131, y: 284)); creases.addLine(to: CGPoint(x: 131, y: 346))
    creases.move(to: CGPoint(x: 204, y: 302)); creases.addLine(to: CGPoint(x: 204, y: 356))
    // Thumb against the index finger.
    creases.move(to: CGPoint(x: -38, y: 300)); creases.addQuadCurve(to: CGPoint(x: -10, y: 470), control: CGPoint(x: -24, y: 400))
    let nail = CGPath(roundedRect: CGRect(x: -26, y: 16, width: 52, height: 58), cornerWidth: 24, cornerHeight: 26, transform: nil)
    return (shape, creases, nail)
}

func drawIcon(_ ctx: CGContext) {
    // Work in a 1024 top-left coordinate space.
    ctx.translateBy(x: 0, y: design)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Drop shadow under the tile, like the standard macOS icon grid.
    ctx.saveGState()
    shadow(ctx, dx: 0, dy: -10, blur: 22, color: rgb(0x000000, 0.32))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x1E2A78)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Background: deep blue with a soft light from the top.
    linear(ctx, [rgb(0x4F7BFF), rgb(0x2C3FD6), rgb(0x1D1F8F)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924), locations: [0, 0.55, 1])
    radial(ctx, [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)], center: CGPoint(x: 330, y: 120), radius: 620)

    // Monitor.
    let monitor = CGRect(x: 176, y: 236, width: 600, height: 420)
    let neck = CGRect(x: 436, y: 640, width: 80, height: 92)
    let foot = rounded(CGRect(x: 356, y: 722, width: 240, height: 30), 15)

    ctx.saveGState()
    shadow(ctx, dx: 0, dy: -26, blur: 44, color: rgb(0x050833, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(foot); ctx.addRect(neck); ctx.addPath(rounded(monitor, 44))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Stand: brushed aluminum.
    ctx.saveGState()
    ctx.addRect(neck); ctx.addPath(foot); ctx.clip()
    linear(ctx, [rgb(0xC9CEDB), rgb(0xF3F5FA), rgb(0xB4BAC9)], from: CGPoint(x: 356, y: 0), to: CGPoint(x: 596, y: 0), locations: [0, 0.5, 1])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addRect(CGRect(x: 436, y: 656, width: 80, height: 18)); ctx.setFillColor(rgb(0x000000, 0.16)); ctx.fillPath()
    ctx.restoreGState()

    // Bezel.
    ctx.saveGState()
    ctx.addPath(rounded(monitor, 44)); ctx.clip()
    linear(ctx, [rgb(0xFBFCFF), rgb(0xDDE2EE)], from: CGPoint(x: 0, y: monitor.minY), to: CGPoint(x: 0, y: monitor.maxY))
    ctx.restoreGState()

    // Screen with a colorful wallpaper.
    let screen = monitor.insetBy(dx: 20, dy: 20)
    let screenPath = rounded(screen, 26)
    ctx.saveGState()
    ctx.addPath(screenPath); ctx.clip()
    linear(ctx, [rgb(0x1BC8F2), rgb(0x6A5CFF), rgb(0xD94CE0), rgb(0xFF8A5B)],
           from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY), locations: [0, 0.38, 0.72, 1])
    radial(ctx, [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)], center: CGPoint(x: screen.minX + 120, y: screen.minY + 80), radius: 320)
    // Wave layers for depth.
    for (i, alpha) in [0.18, 0.12].enumerated() {
        let w = CGMutablePath()
        let y0 = screen.maxY - 150 + CGFloat(i) * 60
        w.move(to: CGPoint(x: screen.minX, y: y0))
        w.addCurve(to: CGPoint(x: screen.maxX, y: y0 - 40),
                   control1: CGPoint(x: screen.minX + 200, y: y0 - 130), control2: CGPoint(x: screen.maxX - 220, y: y0 + 110))
        w.addLine(to: CGPoint(x: screen.maxX, y: screen.maxY)); w.addLine(to: CGPoint(x: screen.minX, y: screen.maxY)); w.closeSubpath()
        ctx.addPath(w); ctx.setFillColor(rgb(0x1A0B5E, alpha)); ctx.fillPath()
    }
    // Menu bar.
    ctx.addRect(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 30))
    ctx.setFillColor(rgb(0xFFFFFF, 0.32)); ctx.fillPath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    for (x, w) in [(24.0, 16.0), (54.0, 46.0), (112.0, 40.0)] as [(CGFloat, CGFloat)] {
        ctx.addPath(rounded(CGRect(x: screen.minX + x, y: screen.minY + 10, width: w, height: 10), 5)); ctx.fillPath()
    }

    // Touch ripples.
    let touch = CGPoint(x: 560, y: 452)
    radial(ctx, [rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0.0)], center: touch, radius: 70)
    for (r, a, lw) in [(58.0, 0.85, 9.0), (100.0, 0.5, 7.0), (142.0, 0.25, 5.0)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.addEllipse(in: CGRect(x: touch.x - r, y: touch.y - r, width: r * 2, height: r * 2))
        ctx.setStrokeColor(rgb(0xFFFFFF, a)); ctx.setLineWidth(lw); ctx.strokePath()
    }
    ctx.restoreGState()

    // Inner screen edge.
    ctx.addPath(screenPath); ctx.setStrokeColor(rgb(0x000000, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

    // Hand.
    let (silhouette, creases, nail) = handParts()
    var t = CGAffineTransform(translationX: touch.x, y: touch.y).rotated(by: -0.52).scaledBy(x: 0.98, y: 0.98)
    let handPath = silhouette.copy(using: &t)!
    let creasePath = creases.copy(using: &t)!
    let nailPath = nail.copy(using: &t)!

    ctx.saveGState()
    shadow(ctx, dx: -6, dy: -30, blur: 46, color: rgb(0x0A0C3D, 0.5))
    ctx.addPath(handPath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(handPath); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF), rgb(0xF2F4FA), rgb(0xD5DAE8)], from: CGPoint(x: 520, y: 430), to: CGPoint(x: 900, y: 940), locations: [0, 0.45, 1])
    ctx.addPath(nailPath); ctx.setFillColor(rgb(0xC9CFE2, 0.35)); ctx.fillPath()
    ctx.addPath(creasePath); ctx.setStrokeColor(rgb(0x7A84A8, 0.35)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(handPath); ctx.setStrokeColor(rgb(0x3A4380, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

    // Top highlight on the tile edge.
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.22)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(pixels) / design
    ctx.scaleBy(x: s, y: s)
    shadowScale = s
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(pixels: base * scale).write(to: out.appendingPathComponent(name))
    }
}
print("Wrote icons to \(out.path)")
