// Draws the Recast app icon (1024×1024 PNG): two arrows turning around three level bars, on a tangerine tile.
// Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// MARK: Family style
// The sibling apps' icon scripts share this part word for word: a solid colour tile shaded slightly lighter at the
// top and one bold cream symbol with a gold accent. Only `tile` and the symbol differ between apps. Change all of them
// together.

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
/// `hex` moved `amount` of the way towards white (positive) or black (negative).
func shade(_ hex: UInt32, _ amount: CGFloat) -> CGColor {
    let c = rgb(hex).components!
    let target: CGFloat = amount > 0 ? 1 : 0
    let t = abs(amount)
    return CGColor(red: c[0] + (target - c[0]) * t, green: c[1] + (target - c[1]) * t, blue: c[2] + (target - c[2]) * t, alpha: 1)
}
let cream = rgb(0xf6f0e4)
let gold = rgb(0xe2b552)
let tile: UInt32 = 0xe8782a  // tangerine

// The tile, on the macOS icon grid: inset from the canvas, with rounded corners and a drop shadow.
let inset: CGFloat = 100
let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                   cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(rgb(tile)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let tileShade = CGGradient(colorsSpace: space, colors: [shade(tile, 0.10), rgb(tile), shade(tile, -0.10)] as CFArray,
                           locations: [0, 0.5, 1])!
cg.drawLinearGradient(tileShade, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
cg.restoreGState()

/// Draws `body` with a soft shadow under it, so the symbol sits just above the tile.
func raised(_ body: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.18))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

// MARK: Symbol

let center = CGPoint(x: size / 2, y: size / 2)

/// A closed path through `points` with each corner rounded by `radius`.
func rounded(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = points.count
    path.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
    for i in 0..<n {
        path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius)
    }
    path.closeSubpath()
    return path
}

raised {
    // Two arcs turning clockwise, up the left side and down the right, each ending in a level gold arrowhead with
    // rounded corners: at the top pointing right, at the bottom pointing left.
    let radius: CGFloat = 282, ring: CGFloat = 50
    let length: CGFloat = 124, half: CGFloat = 62
    let reach = asin(length / 2 / radius)  // half a head's length, as an angle round the circle
    let gap: CGFloat = 14 * .pi / 180  // between a head's tip and the next arc's tail
    func arc(from start: CGFloat, to end: CGFloat) {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        cg.addPath(path)
        cg.setStrokeColor(cream); cg.setLineWidth(ring); cg.setLineCap(.round)
        cg.strokePath()
    }
    arc(from: 1.5 * .pi - reach - gap, to: 0.5 * .pi + reach)
    arc(from: 0.5 * .pi - reach - gap, to: -0.5 * .pi + reach)
    // Each head sits on the chord between where its arc stops and where the next one would start.
    let rise = radius * cos(reach)
    for (y, direction) in [(center.y + rise, 1), (center.y - rise, -1)] as [(CGFloat, CGFloat)] {
        let base = center.x - direction * length / 2, tip = center.x + direction * length / 2
        let head = rounded([CGPoint(x: tip, y: y), CGPoint(x: base, y: y + half), CGPoint(x: base, y: y - half)], radius: 16)
        cg.addPath(head); cg.setFillColor(gold); cg.fillPath()
    }

    // Three level bars, tallest in the middle: few and thick, so they stay apart at small sizes.
    let heights: [CGFloat] = [170, 310, 170]
    let barWidth: CGFloat = 62, gapBetween: CGFloat = 48
    var x = center.x - (3 * barWidth + 2 * gapBetween) / 2
    for height in heights {
        let bar = CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        cg.setFillColor(cream); cg.fillPath()
        x += barWidth + gapBetween
    }
}

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
