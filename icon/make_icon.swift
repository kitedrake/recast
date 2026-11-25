// Draws the Recast app icon (1024×1024 PNG): two arrows turning around three level bars, on an ochre tile.
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
// top, one bold cream symbol with a gold accent, and a small kite tail in the lower-right corner. Only `tile` and the
// symbol differ between apps. Change all of them together.

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
let tile: UInt32 = 0xb8862a  // ochre

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

/// The family mark: a wavy cream ribbon hanging from a gold bow, like a kite's tail.
func kiteTail() {
    let knot = CGPoint(x: 796, y: 246)
    let ribbon = CGMutablePath()
    let steps = 40
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: knot.x + sin(t * 2 * .pi) * (6 + 10 * t), y: knot.y - 96 * t)
        if i == 0 { ribbon.move(to: point) } else { ribbon.addLine(to: point) }
    }
    cg.addPath(ribbon)
    cg.setStrokeColor(cream); cg.setLineWidth(15); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.strokePath()
    let s: CGFloat = 21
    let bow = CGMutablePath()
    for side: CGFloat in [-1, 1] {
        bow.move(to: knot)
        bow.addLine(to: CGPoint(x: knot.x + side * s, y: knot.y + s * 0.7))
        bow.addLine(to: CGPoint(x: knot.x + side * s, y: knot.y - s * 0.7))
        bow.closeSubpath()
    }
    cg.addPath(bow); cg.setFillColor(gold); cg.fillPath()
    cg.addEllipse(in: CGRect(x: knot.x - 6, y: knot.y - 6, width: 12, height: 12)); cg.fillPath()
}

// MARK: Symbol

let center = CGPoint(x: size / 2, y: size / 2)

raised {
    // Two arcs turning clockwise, each ending in a gold arrowhead: up the left side to the top, down the right side
    // to the bottom.
    let radius: CGFloat = 282, ring: CGFloat = 50
    func onCircle(_ angle: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }
    func arrow(from start: CGFloat, to end: CGFloat) {
        let a0 = start * .pi / 180, a1 = end * .pi / 180
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        cg.addPath(arc)
        cg.setStrokeColor(cream); cg.setLineWidth(ring); cg.setLineCap(.round)
        cg.strokePath()
        // The head follows the circle: its base straddles the arc's end, its tip lies further round.
        let length: CGFloat = 116, half: CGFloat = 60
        let base = a1 + 0.06, tip = a1 - length / radius
        let head = CGMutablePath()
        head.move(to: onCircle(tip, radius))
        head.addLine(to: onCircle(base, radius + half))
        head.addLine(to: onCircle(base, radius - half))
        head.closeSubpath()
        cg.addPath(head); cg.setFillColor(gold); cg.setLineJoin(.round); cg.setLineWidth(10)
        cg.setStrokeColor(gold); cg.drawPath(using: .fillStroke)
    }
    arrow(from: 254, to: 112)
    arrow(from: 74, to: -68)

    // Three level bars, tallest in the middle: few and thick, so they stay apart at small sizes.
    let heights: [CGFloat] = [170, 310, 170]
    let barWidth: CGFloat = 62, gap: CGFloat = 48
    var x = center.x - (3 * barWidth + 2 * gap) / 2
    for height in heights {
        let bar = CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        cg.setFillColor(cream); cg.fillPath()
        x += barWidth + gap
    }
}
kiteTail()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
