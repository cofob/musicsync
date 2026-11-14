// Draws the MusicSync app icon with CoreGraphics.
// Usage: swift scripts/make-icon.swift <a|b|c> <outdir>   -> icon-<x>.png + AppIcon.iconset/
//        swift scripts/make-icon.swift sheet <outdir>     -> icon-a/b/c.png + contact-sheet.png
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}

func save(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

// macOS icon grid: 824 pt body centered on a 1024 canvas, rounded-square base.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let C = CGPoint(x: 512, y: 512)

func squircle(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.width * 0.225, cornerHeight: r.height * 0.225, transform: nil)
}

func linear(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func fill(_ c: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    c.saveGState(); c.addPath(path); c.clip(); linear(c, colors, from: from, to: to); c.restoreGState()
}

func circle(_ center: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func pt(_ center: CGPoint, _ r: CGFloat, _ deg: CGFloat) -> CGPoint {
    CGPoint(x: center.x + r * cos(deg * .pi / 180), y: center.y + r * sin(deg * .pi / 180))
}

// Squircle base with drop shadow, gradient, glass sheen and hairline rim.
func base(_ c: CGContext, _ top: CGColor, _ bottom: CGColor) {
    let s = squircle(body)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0.35))
    c.addPath(s); c.setFillColor(bottom); c.fillPath()
    c.restoreGState()
    fill(c, s, [top, bottom], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    fill(c, s, [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
    c.saveGState()
    c.addPath(squircle(body.insetBy(dx: 2, dy: 2))); c.setStrokeColor(rgb(0xFFFFFF, 0.28)); c.setLineWidth(4); c.strokePath()
    c.restoreGState()
}

// Glyphs get a soft shadow so they lift off the base.
func lifted(_ c: CGContext, _ draw: () -> Void) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x5A0010, 0.35))
    c.beginTransparencyLayer(auxiliaryInfo: nil); draw(); c.endTransparencyLayer()
    c.restoreGState()
}

// Arc stroke (counter-clockwise from a0 to a1) ending in an arrowhead.
func arrowArc(_ c: CGContext, r: CGFloat, w: CGFloat, a0: CGFloat, a1: CGFloat, head: CGFloat) {
    let headDeg = head / r * 180 / .pi
    let p = CGMutablePath()
    p.addArc(center: C, radius: r, startAngle: a0 * .pi / 180, endAngle: (a1 - headDeg * 0.6) * .pi / 180, clockwise: false)
    c.addPath(p); c.setLineWidth(w); c.setLineCap(.round); c.strokePath()
    let tip = pt(C, r, a1), back = a1 - headDeg
    let h = CGMutablePath()
    h.move(to: tip)
    h.addLine(to: pt(C, r + w * 1.25, back))
    h.addLine(to: pt(C, r - w * 1.25, back))
    h.closeSubpath()
    c.addPath(h); c.setLineJoin(.round); c.setLineWidth(w * 0.25)
    c.drawPath(using: .fillStroke)
}

let red = rgb(0xFF5A6E), deep = rgb(0xE5173F)

// A: click-wheel ring made of two sync arrows around a center button.
func conceptA(_ c: CGContext) {
    base(c, rgb(0xFF6A7E), rgb(0xE3123C))
    lifted(c) {
        c.addPath(circle(C, 330)); c.setFillColor(rgb(0xFFFFFF, 0.14)); c.fillPath()
        c.setStrokeColor(.white); c.setFillColor(.white)
        arrowArc(c, r: 240, w: 74, a0: 105, a1: 255, head: 175)
        arrowArc(c, r: 240, w: 74, a0: 285, a1: 435, head: 175)
        c.addPath(circle(C, 84)); c.fillPath()
    }
}

// B: eighth note whose head is a click-wheel ring with a center button.
func conceptB(_ c: CGContext) {
    base(c, rgb(0xFF6A7E), rgb(0xE3123C))
    let head = CGPoint(x: 420, y: 380), R: CGFloat = 170, w: CGFloat = 70
    lifted(c) {
        c.setStrokeColor(.white); c.setFillColor(.white)
        c.addPath(circle(head, R - w / 2)); c.setLineWidth(w); c.strokePath()
        c.addPath(circle(head, 52)); c.fillPath()
        let sx = head.x + R - w
        let stem = CGPath(roundedRect: CGRect(x: sx, y: head.y, width: w, height: 370), cornerWidth: 0, cornerHeight: 0, transform: nil)
        c.addPath(stem); c.fillPath()
        let flag = CGMutablePath(), top = head.y + 410
        flag.move(to: CGPoint(x: sx, y: top - 40))
        flag.addLine(to: CGPoint(x: sx, y: top))
        flag.addCurve(to: CGPoint(x: sx + 230, y: top - 210), control1: CGPoint(x: sx + 120, y: top - 10), control2: CGPoint(x: sx + 250, y: top - 110))
        flag.addCurve(to: CGPoint(x: sx + w - 4, y: top - 150), control1: CGPoint(x: sx + 210, y: top - 150), control2: CGPoint(x: sx + 140, y: top - 120))
        flag.closeSubpath()
        c.addPath(flag); c.fillPath()
    }
}

// C: graphite base, record disc with a pink sync-down arrow into a device tray.
func conceptC(_ c: CGContext) {
    base(c, rgb(0x48484E), rgb(0x1C1C20))
    let disc = CGPoint(x: 512, y: 590), R: CGFloat = 270
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0.5))
    c.addPath(circle(disc, R)); c.setFillColor(rgb(0x0E0E10)); c.fillPath()
    c.restoreGState()
    c.setStrokeColor(rgb(0xFFFFFF, 0.08)); c.setLineWidth(3)
    for r in stride(from: R - 25, to: 155, by: -22) { c.addPath(circle(disc, r)); c.strokePath() }
    fill(c, circle(disc, 140), [red, deep], from: CGPoint(x: 512, y: 705), to: CGPoint(x: 512, y: 495))
    // sheen
    c.saveGState(); c.addPath(circle(disc, R)); c.clip()
    linear(c, [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)], from: CGPoint(x: 330, y: 820), to: CGPoint(x: 512, y: 600))
    c.restoreGState()
    // tray + arrow
    let tray = CGMutablePath()
    tray.addRoundedRect(in: CGRect(x: 262, y: 196, width: 500, height: 70), cornerWidth: 35, cornerHeight: 35)
    let arrow = CGMutablePath()
    arrow.addRoundedRect(in: CGRect(x: 482, y: 560, width: 60, height: 120), cornerWidth: 14, cornerHeight: 14)
    arrow.move(to: CGPoint(x: 512, y: 500)); arrow.addLine(to: CGPoint(x: 590, y: 580)); arrow.addLine(to: CGPoint(x: 434, y: 580)); arrow.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0.5))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(c, tray, [red, deep], from: CGPoint(x: 512, y: 266), to: CGPoint(x: 512, y: 196))
    c.addPath(arrow); c.setFillColor(.white); c.fillPath()
    c.endTransparencyLayer()
    c.restoreGState()
}

func render(_ concept: String) -> CGImage {
    let c = bitmap(1024, 1024)
    switch concept {
    case "a": conceptA(c)
    case "b": conceptB(c)
    case "c": conceptC(c)
    default: fatalError("unknown concept \(concept)")
    }
    return c.makeImage()!
}

func scaled(_ img: CGImage, _ px: Int) -> CGImage {
    let c = bitmap(px, px)
    c.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    return c.makeImage()!
}

func iconset(_ img: CGImage, _ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for s in [16, 32, 128, 256, 512] {
        save(scaled(img, s), "\(dir)/icon_\(s)x\(s).png")
        save(scaled(img, s * 2), "\(dir)/icon_\(s)x\(s)@2x.png")
    }
}

// Rows per concept: 1024 (shown at 256), then 128, 32, 16 at native px and magnified 4x, on light and dark.
func sheet(_ imgs: [CGImage]) -> CGImage {
    let row = 300, W = 1700, c = bitmap(W, row * imgs.count)
    for (i, img) in imgs.enumerated() {
        for (j, bg) in [rgb(0xF2F2F7), rgb(0x1C1C1E)].enumerated() {
            let y = (imgs.count - 1 - i) * row, x0 = j * W / 2
            c.setFillColor(bg); c.fill(CGRect(x: x0, y: y, width: W / 2, height: row))
            c.draw(img, in: CGRect(x: x0 + 20, y: y + 22, width: 256, height: 256))
            c.draw(scaled(img, 128), in: CGRect(x: x0 + 290, y: y + 86, width: 128, height: 128))
            c.interpolationQuality = .none
            c.draw(scaled(img, 32), in: CGRect(x: x0 + 440, y: y + 86, width: 128, height: 128))
            c.draw(scaled(img, 16), in: CGRect(x: x0 + 590, y: y + 86, width: 128, height: 128))
            c.interpolationQuality = .high
            c.draw(scaled(img, 32), in: CGRect(x: x0 + 740, y: y + 40, width: 32, height: 32))
            c.draw(scaled(img, 16), in: CGRect(x: x0 + 790, y: y + 40, width: 16, height: 16))
        }
    }
    return c.makeImage()!
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon.swift <a|b|c|sheet> <outdir>"); exit(1) }
let out = args[2]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
if args[1] == "sheet" {
    let imgs = ["a", "b", "c"].map(render)
    for (k, img) in zip(["a", "b", "c"], imgs) { save(img, "\(out)/icon-\(k).png") }
    save(sheet(imgs), "\(out)/contact-sheet.png")
} else {
    let img = render(args[1])
    save(img, "\(out)/icon-\(args[1]).png")
    iconset(img, "\(out)/AppIcon.iconset")
}
