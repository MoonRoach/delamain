// Images and the static city layer: sprites keyed like viz.html, and a Core Graphics render of the ground, streets,
// highways and schematic lots for one camera view at the screen's backing resolution.
import AppKit
import QuartzCore

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 255) / 255; g = CGFloat((hex >> 8) & 255) / 255; b = CGFloat(hex & 255) / 255
    }
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = CGFloat(r) / 255; self.g = CGFloat(g) / 255; self.b = CGFloat(b) / 255 }
    func cg(_ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: CGFloat(max(0, min(1, a)))) }
    func ns(_ a: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: CGFloat(max(0, min(1, a)))) }
    var key: UInt32 { UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255) }
}

enum Pal {
    static let amber = RGB(0xffb547), cyan = RGB(0x4fe3ff), violet = RGB(0xc08bff), magenta = RGB(0xff4fd8)
    static let gold = RGB(0xffd76a), ink = RGB(0xdfe6ee), dim = RGB(0x8a96a6), tool = RGB(0x9fb4c8), red = RGB(0xff3b5c)
    static func engine(_ e: String) -> RGB { e == "codex" ? cyan : e == "claude" ? amber : tool }
}

let TOWERS = ["hub-tower", "hub-tower-cyan", "hub-tower-red", "hub-tower-green", "hub-tower-gold", "hub-tower-blue",
              "hub-tower-white"]   // one per stage, by its name's hash
let CABS = ["flyer", "flyer-sport", "flyer-van", "flyer-police", "flyer-limo", "flyer-bike"]

/// A worker's flyer shows its model's tier, as the page's cabSprite: limo for the flagship, sports flyer for Opus, the plain
/// flyer for the workhorse, a bike for the light model, a van for a service tool; an unknown model by the key's hash.
func cabSprite(model: String, engine: String, key: String) -> String {
    let m = model.lowercased(), has = { (s: String) in m.contains(s) }
    if has("fable") || has("astra") { return "flyer-limo" }
    if has("opus") { return "flyer-sport" }
    if has("sonnet") || m.range(of: "(^|[^a-z])sol([^a-z]|$)", options: .regularExpression) != nil { return "flyer" }   // sol as a word
    if has("haiku") || has("luna") { return "flyer-bike" }
    if !engine.isEmpty && engine != "claude" && engine != "codex" { return "flyer-van" }
    return CABS[Int(jsHash(key) % UInt32(CABS.count))]
}
let SPRITE_NAMES = TOWERS + CABS + ["owner-tower", "holo", "block", "corpo-block", "industrial-block", "residential-block",
                                    "market-block", "port-block", "luxury-block", "badlands-block", "megamall", "data-center",
                                    "landing-pad", "power-plant", "container-ship", "oil-rig", "billboard-tower", "park",
                                    "slum-block", "temple", "stadium", "water-tower", "monorail-station"]
let SOLID: Set<String> = Set(TOWERS + CABS + ["owner-tower"])
let AFLOAT: Set<String> = ["container-ship", "oil-rig"]   // standing in the bay off their lot

final class Sprites {
    private(set) var images: [String: CGImage] = [:]
    private(set) var sky: CGImage?

    init(bundle: Bundle) {
        for name in SPRITE_NAMES {
            guard let url = bundle.url(forResource: name, withExtension: "png"), let img = Sprites.load(url) else { continue }
            images[name] = Sprites.key(img, solid: SOLID.contains(name))
        }
        if let url = bundle.url(forResource: "skyline", withExtension: "jpg") { sky = Sprites.load(url) }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// The black background keyed to alpha: soft key (max(r,g,b) - 5) * 12, or for a SOLID sprite each row's span
    /// between its outer lit pixels made opaque.
    static func key(_ img: CGImage, solid: Bool) -> CGImage {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let out: CGImage? = px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = buf.bindMemory(to: UInt8.self)
            @inline(__always) func mx(_ k: Int) -> Int { Int(max(p[k], p[k + 1], p[k + 2])) }
            @inline(__always) func soft(_ k: Int) -> Int { max(0, min(255, (mx(k) - 5) * 12)) }
            var alpha = [UInt8](repeating: 0, count: w * h)
            if !solid {
                for i in 0..<(w * h) { alpha[i] = UInt8(soft(i * 4)) }
            } else {
                for y in 0..<h {
                    var x0 = -1, x1 = -1
                    for x in 0..<w where mx((y * w + x) * 4) > 14 { if x0 < 0 { x0 = x }; x1 = x }
                    for x in 0..<w {
                        let k = (y * w + x) * 4
                        alpha[y * w + x] = x0 >= 0 && x > x0 && x < x1 && x1 - x0 > 2 ? 255 : UInt8(soft(k))
                    }
                }
            }
            for i in 0..<(w * h) {   // premultiply the original colour by the key
                let a = Int(alpha[i]), k = i * 4
                p[k] = UInt8(Int(p[k]) * a / 255); p[k + 1] = UInt8(Int(p[k + 1]) * a / 255); p[k + 2] = UInt8(Int(p[k + 2]) * a / 255)
                p[k + 3] = UInt8(a)
            }
            return ctx.makeImage()
        }
        return out ?? img
    }
}

// ---- the static layer --------------------------------------------------------------------------------------------

/// One camera view of the static city: iso centre (cx, cy), zoom z, for a screen of W x H points with scale K.
struct StaticView: Equatable {
    var cx: Double, cy: Double, z: Double
    var W: Double, H: Double, K: Double, pad: Double, scale: Double
    var excluded: [Int]   // lots under a tower, sorted
}

struct StaticImage {
    let view: StaticView
    let image: CGImage
    let unit: Double
    let ms: Double
}

enum StaticRenderer {
    static func render(_ v: StaticView, city: CityModel, sprites: [String: CGImage]) -> StaticImage? {
        let t0 = Date()
        let wpt = v.W + 2 * v.pad, hpt = v.H + 2 * v.pad
        let pw = Int(ceil(wpt * v.scale)), ph = Int(ceil(hpt * v.scale))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // top-left origin in the render-time screen's points, the padding around it
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: CGFloat(v.scale), y: -CGFloat(v.scale))
        ctx.translateBy(x: CGFloat(v.pad), y: CGFloat(v.pad))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        let u = v.K * v.z
        func P(_ x: Double, _ y: Double, _ lift: Double = 0) -> CGPoint {
            let a = x - y, b = (x + y) * 0.5
            return CGPoint(x: v.W / 2 + (a - v.cx) * u, y: v.H / 2 + 30 + (b - v.cy) * u - lift * u)
        }
        let minX = -v.pad - 80, maxX = v.W + v.pad + 80, minY = -v.pad - 80, maxY = v.H + v.pad + 80
        func visible(_ p: CGPoint, _ m: Double = 0) -> Bool {
            Double(p.x) > minX - m && Double(p.x) < maxX + m && Double(p.y) > minY - m && Double(p.y) < maxY + m
        }
        func polyPath(_ pts: [(Double, Double)]) -> CGPath {
            let path = CGMutablePath()
            for (k, (x, y)) in pts.enumerated() { if k == 0 { path.move(to: P(x, y)) } else { path.addLine(to: P(x, y)) } }
            path.closeSubpath()
            return path
        }
        // the bay, with neon reflections (frozen at one moment)
        ctx.saveGState()
        ctx.addPath(polyPath(city.water)); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [RGB(6, 18, 38).cg(0.95), RGB(10, 8, 30).cg(0.95)] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: v.W * 0.6, y: v.H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        ctx.setBlendMode(.plusLighter)
        for k in 0..<70 {
            let y = Double((k * 37) % 160 - 20), x = coast(y) - 3 - Double((k * 13) % 23) - sin(Double(k)) * 1.5
            let p = P(x, y), w = u * Double(1 + k % 4)
            ctx.setFillColor((k % 3 != 0 ? Pal.magenta : Pal.cyan).cg(0.08 + 0.06 * sin(Double(k))))
            ctx.fill(CGRect(x: p.x, y: p.y, width: w, height: max(1, u * 0.12)))
        }
        ctx.setBlendMode(.normal)
        ctx.addPath(polyPath(city.world)); ctx.setFillColor(RGB(22, 14, 10).cg(0.92)); ctx.fillPath()   // desert
        ctx.addPath(polyPath(city.city)); ctx.setFillColor(RGB(9, 9, 20).cg(0.96)); ctx.fillPath()
        // streets first, then highways over them
        let nodes = city.nodes
        func segPath(_ segs: [(Int, Int)]) -> CGPath {
            let path = CGMutablePath()
            for (a, b) in segs {
                let pa = P(nodes[a].x, nodes[a].y), pb = P(nodes[b].x, nodes[b].y)
                if !visible(pa, 40) && !visible(pb, 40) { continue }
                path.move(to: CGPoint(x: pa.x, y: pa.y)); path.addLine(to: CGPoint(x: pb.x, y: pb.y))
            }
            return path
        }
        ctx.setLineCap(.round)
        ctx.addPath(segPath(city.streets)); ctx.setStrokeColor(RGB(150, 120, 230).cg(0.15)); ctx.setLineWidth(max(1, u * 0.32)); ctx.strokePath()
        ctx.addPath(segPath(city.highways)); ctx.setStrokeColor(RGB(150, 120, 230).cg(0.2)); ctx.setLineWidth(max(1, u * 0.6)); ctx.strokePath()   // highways: plain, wider
        ctx.setLineCap(.butt)
        // lots, in painter's order by depth on the map
        let excluded = Set(v.excluded)
        let order = city.lots.enumerated().filter { !excluded.contains($0.element.idx) && !$0.element.owner }
            .sorted { let a = $0.element.x + $0.element.y, b = $1.element.x + $1.element.y; return a != b ? a < b : $0.offset < $1.offset }
        for (_, l) in order {
            if l.landmark { drawLandmark(ctx, l, P, u, visible, sprites) } else { drawLot(ctx, l, city, P, u, visible) }
        }
        guard let image = ctx.makeImage() else { return nil }
        return StaticImage(view: v, image: image, unit: u, ms: Date().timeIntervalSince(t0) * 1000)
    }

    private static func drawLot(_ ctx: CGContext, _ l: Lot, _ city: CityModel, _ P: (Double, Double, Double) -> CGPoint, _ u: Double,
                                _ visible: (CGPoint, Double) -> Bool) {
        let col = RGB(TINT[l.d] ?? 0xffffff), dim = DIST[l.d]?.dim ?? 1, k = 0.16   // inset from the streets
        let q = l.quad.map { id -> (Double, Double) in let n = city.nodes[id]; return (n.x + (l.x - n.x) * k * 2, n.y + (l.y - n.y) * k * 2) }
        let c = P(l.x, l.y, 0)
        if !visible(c, 0) { return }
        let h = l.tall, base = q.map { P($0.0, $0.1, 0) }, top = q.map { P($0.0, $0.1, h) }
        // the two faces turned to the viewer, then the roof with a neon rim
        for i in 0..<4 {
            let j = (i + 1) % 4, (ax, ay) = q[i], (bx, by) = q[j]
            let nx = by - ay, ny = -(bx - ax)
            let dotv = (ax - l.x) * nx + (ay - l.y) * ny
            let sgn: Double = dotv == 0 || dotv.isNaN ? 1 : (dotv > 0 ? 1 : -1)
            if (nx + ny) * sgn <= 0 { continue }
            let path = CGMutablePath()
            path.move(to: base[i]); path.addLine(to: base[j]); path.addLine(to: top[j]); path.addLine(to: top[i]); path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(RGB(10, 10, 24).cg(0.92 * dim)); ctx.fillPath()
            ctx.addPath(path); ctx.setStrokeColor(col.cg(0.22 * dim)); ctx.setLineWidth(1); ctx.strokePath()
        }
        let roof = CGMutablePath()
        roof.addLines(between: top); roof.closeSubpath()
        ctx.addPath(roof); ctx.setFillColor(col.cg(0.07 * dim)); ctx.fillPath()
        let flick = l.h % 9 == 0 ? 0.75 : 1   // the page flickers these; the static layer holds the middle value
        ctx.addPath(roof); ctx.setStrokeColor(col.cg((0.35 + Double(l.h % 4) * 0.08) * dim * flick)); ctx.setLineWidth(max(1, u * 0.12)); ctx.strokePath()
        if l.h % 3 == 0 {   // a lit window strip on the front edge
            let (x1, y1) = (Double(top[2].x), Double(top[2].y)), (x2, y2) = (Double(top[3].x), Double(top[3].y))
            ctx.setStrokeColor(col.cg(0.5 * dim)); ctx.setLineWidth(max(1, u * 0.1))
            ctx.move(to: CGPoint(x: x1 + (x2 - x1) * 0.2, y: y1 + (y2 - y1) * 0.2 + u * h * 0.45))
            ctx.addLine(to: CGPoint(x: x1 + (x2 - x1) * 0.8, y: y1 + (y2 - y1) * 0.8 + u * h * 0.45))
            ctx.strokePath()
        }
    }

    /// A landmark is a whole building, not one lot: its sprite is drawn this many times a lot's width.
    private static let LANDMARK_SCALE: [String: Double] = [
        "corpo-block": 2.4, "port-block": 2.2, "industrial-block": 2.2, "market-block": 1.8, "block": 1.8,
        "badlands-block": 1.3, "residential-block": 1.9, "luxury-block": 2.1, "megamall": 2.6, "data-center": 2.2,
        "landing-pad": 1.9, "power-plant": 2.5, "container-ship": 2.7, "oil-rig": 2.3, "billboard-tower": 1.7, "park": 2.1,
        "slum-block": 2.1, "temple": 2, "stadium": 2.7, "water-tower": 1.5, "monorail-station": 2.1]
    private static func drawLandmark(_ ctx: CGContext, _ l: Lot, _ P: (Double, Double, Double) -> CGPoint, _ u: Double,
                                     _ visible: (CGPoint, Double) -> Bool, _ sprites: [String: CGImage]) {
        guard let s = sprites[l.sprite] ?? sprites["block"] else { return }
        let p = P(AFLOAT.contains(l.sprite) ? coast(l.y) - 4 : l.x, l.y, 0), w = l.size * 2 * u * 1.1 * (LANDMARK_SCALE[l.sprite] ?? 1.8), h = w * Double(s.height) / Double(s.width)
        if !visible(p, w) { return }
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: l.flip ? -1 : 1, y: -1)   // the context is flipped; images draw upright
        ctx.setAlpha(CGFloat(0.6 * (DIST[l.d]?.dim ?? 1)))   // scenery: fainter than the towers and cabs, which are live
        // canvas rect (-w/2, -h*0.6, w, h) with y down; in the y-up local space its top is at +h*0.6
        ctx.draw(s, in: CGRect(x: -w / 2, y: -(h - h * 0.6), width: w, height: h))
        ctx.restoreGState()
    }
}
