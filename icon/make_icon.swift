// Draws the Recast app icon (1024×1024 PNG): two folded arrows turning around three level bars, in tangerine on a
// cream paper tile. Run by icon/make-icns.sh.
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
// The sibling apps' icon scripts share this part word for word: one glyph folded from paper in the app's own ink, a
// few flat facets lit from the top left, on a cream paper tile, with a gold accent. Only `ink` and the symbol differ
// between apps. Change all of them together.

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
/// `a` moved `t` of the way towards `b`.
func blend(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let x = a.components!, y = b.components!
    return CGColor(red: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t, blue: x[2] + (y[2] - x[2]) * t, alpha: 1)
}
/// `hex` moved `amount` of the way towards white (positive) or black (negative).
func shade(_ hex: UInt32, _ amount: CGFloat) -> CGColor {
    blend(rgb(hex), rgb(amount > 0 ? 0xffffff : 0x000000), abs(amount))
}
let paper: UInt32 = 0xf6f0e4
let gold: UInt32 = 0xd9a23c
let ink: UInt32 = 0xe8782a  // tangerine
// Each colour in three tones: facets facing the light, across it, and away from it.
let light = shade(ink, 0.16), mid = rgb(ink), dark = shade(ink, -0.26)
let goldLight = shade(gold, 0.18), goldMid = rgb(gold), goldDark = shade(gold, -0.24)
let cream = rgb(paper), creamShade = shade(paper, -0.12)

// The tile, on the macOS icon grid: cream paper inset from the canvas, with rounded corners and a drop shadow.
let inset: CGFloat = 100
let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                   cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
cg.addPath(shape); cg.setFillColor(cream); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let tileShade = CGGradient(colorsSpace: space, colors: [shade(paper, 0.55), cream, shade(paper, -0.06)] as CFArray,
                           locations: [0, 0.55, 1])!
cg.drawLinearGradient(tileShade, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
cg.restoreGState()

/// Draws `body` with a soft shadow under it, so the paper sits just above the tile.
func raised(_ body: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.22))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

/// Fills one flat facet. The thin stroke in the same colour closes the seams between neighbouring facets.
func facet(_ color: CGColor, _ points: [CGPoint]) {
    cg.move(to: points[0])
    for point in points.dropFirst() { cg.addLine(to: point) }
    cg.closePath()
    cg.setFillColor(color); cg.setStrokeColor(color); cg.setLineWidth(1.5); cg.setLineJoin(.round)
    cg.drawPath(using: .fillStroke)
}
func facet(_ color: CGColor, _ points: [(CGFloat, CGFloat)]) { facet(color, points.map { CGPoint(x: $0.0, y: $0.1) }) }

/// The tone of a facet that faces `angle` (radians, 0 = right): `lit` facing the top left, `unlit` the bottom right.
func tone(_ angle: CGFloat, _ lit: CGColor, _ unlit: CGColor) -> CGColor {
    blend(unlit, lit, (cos(angle - 3 * .pi / 4) + 1) / 2)
}

/// A paper strip `width` across, folded along `points`: each straight run is one facet, the creases are mitred, and the
/// runs take `tones` in turn.
func strip(_ points: [CGPoint], width: CGFloat, tones: [CGColor]) {
    let n = points.count
    let dirs = (0..<n - 1).map { i -> CGPoint in
        let dx = points[i + 1].x - points[i].x, dy = points[i + 1].y - points[i].y, l = hypot(dx, dy)
        return CGPoint(x: dx / l, y: dy / l)
    }
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0..<n {
        let a = dirs[max(i - 1, 0)], b = dirs[min(i, n - 2)]
        let na = CGPoint(x: -a.y, y: a.x), nb = CGPoint(x: -b.y, y: b.x)
        let mx = na.x + nb.x, my = na.y + nb.y, ml = hypot(mx, my)
        let length = width / 2 / ((mx * na.x + my * na.y) / ml)
        left.append(CGPoint(x: points[i].x + mx / ml * length, y: points[i].y + my / ml * length))
        right.append(CGPoint(x: points[i].x - mx / ml * length, y: points[i].y - my / ml * length))
    }
    for i in 0..<n - 1 { facet(tones[i % tones.count], [left[i], left[i + 1], right[i + 1], right[i]]) }
}

/// A four-pointed gold star folded from paper: each point is two facets meeting along its spine.
func sparkle(_ center: CGPoint, _ radius: CGFloat) {
    for k in 0..<4 {
        let a = CGFloat(k) * .pi / 2 + .pi / 2
        let tip = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        for side: CGFloat in [-1, 1] {
            let s = a + side * .pi / 4
            let corner = CGPoint(x: center.x + cos(s) * radius * 0.3, y: center.y + sin(s) * radius * 0.3)
            facet(tone(a + side * .pi / 2, goldLight, goldDark), [center, tip, corner])
        }
    }
}

// MARK: Symbol

// Two folded paper arcs turning clockwise around three folded level bars, each arc ending in a gold arrowhead.
let center = CGPoint(x: size / 2, y: size / 2)

raised {
    let radius: CGFloat = 282, ring: CGFloat = 66
    /// An arc from `start` to `end` degrees, clockwise, folded into straight runs, with a gold head at its end.
    func arrow(from start: CGFloat, to end: CGFloat) {
        let steps = 7
        let angle = { (i: CGFloat) -> CGFloat in (start + (end - start) * i / CGFloat(steps)) * .pi / 180 }
        let points = (0...steps).map { CGPoint(x: center.x + cos(angle(CGFloat($0))) * radius,
                                               y: center.y + sin(angle(CGFloat($0))) * radius) }
        strip(points, width: ring, tones: (0..<steps).map { tone(angle(CGFloat($0) + 0.5), light, dark) })
        // The head continues the last run: its base straddles the arc's end, split along its spine.
        let a = points[steps - 1], b = points[steps]
        let l = hypot(b.x - a.x, b.y - a.y), dx = (b.x - a.x) / l, dy = (b.y - a.y) / l
        let length: CGFloat = 120, half: CGFloat = 68
        let tip = CGPoint(x: b.x + dx * length, y: b.y + dy * length)
        let outer = CGPoint(x: b.x + dy * half, y: b.y - dx * half), inner = CGPoint(x: b.x - dy * half, y: b.y + dx * half)
        let out = angle(CGFloat(steps))
        facet(tone(out, goldLight, goldDark), [tip, outer, b])
        facet(tone(out + .pi, goldLight, goldDark), [tip, b, inner])
    }
    arrow(from: 250, to: 112)
    arrow(from: 70, to: -68)

    // Three level bars, tallest in the middle, each folded down its middle with pointed ends.
    let heights: [CGFloat] = [176, 316, 176]
    let barWidth: CGFloat = 70, gap: CGFloat = 46, point: CGFloat = 18
    var x = center.x - (3 * barWidth + 2 * gap) / 2
    for height in heights {
        let y0 = center.y - height / 2, y1 = center.y + height / 2, xm = x + barWidth / 2
        facet(light, [(x, y0 + point), (xm, y0), (xm, y1), (x, y1 - point)])
        facet(mid, [(xm, y0), (x + barWidth, y0 + point), (x + barWidth, y1 - point), (xm, y1)])
        x += barWidth + gap
    }
}

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
