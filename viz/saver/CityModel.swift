// The city of viz.html, ported line by line: geography, districts, the street graph, lots, landmarks and hub
// placement. It must stay deterministic exactly like the page (same PRNG, same hash, same call order), so the
// native city and the web city are the same city.
import Foundation

// ---- deterministic randomness: bit-for-bit with the page ----------------------------------------------------

/// FNV-1a over what JS `for (const ch of s) ch.charCodeAt(0)` sees: the first UTF-16 unit of each code point.
func jsHash(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for sc in s.unicodeScalars {
        let v = sc.value
        let unit: UInt32 = v > 0xFFFF ? 0xD800 + ((v - 0x10000) >> 10) : v
        h = (h ^ unit) &* 16777619
    }
    return h
}

/// mulberry32, as the page's `mulberry(a)`.
final class Mulberry {
    private var a: UInt32
    init(_ seed: UInt32) { a = seed }
    func callAsFunction() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296
    }
}

/// V8's Math.hypot (scaled, compensated sum), so distance comparisons tie-break like the page.
func jsHypot(_ x: Double, _ y: Double) -> Double {
    let ax = abs(x), ay = abs(y), m = max(ax, ay)
    if m == 0 { return 0 }
    if m.isInfinite { return .infinity }
    var sum = 0.0, comp = 0.0
    for v in [ax, ay] {
        let n = v / m, summand = n * n - comp, pre = sum + summand
        comp = (pre - sum) - summand
        sum = pre
    }
    return sum.squareRoot() * m
}

// ---- geography ------------------------------------------------------------------------------------------------
// World units: x east, y south. Water to the west of the coast, desert outside the city blob.
let CX = 54.0, CY = 64.0
func coast(_ y: Double) -> Double { 9 + 5 * sin(y / 13) + 2.5 * sin(y / 5.3 + 1) }
func inCity(_ x: Double, _ y: Double) -> Bool {
    let a = atan2(y - CY, x - CX), wob = 1 + 0.08 * sin(a * 5 + 1) + 0.05 * sin(a * 9)
    let dx = (x - CX) / 44, dy = (y - CY) / 58
    return dx * dx + dy * dy < wob * wob && x > coast(y) + 1
}
func inWorld(_ x: Double, _ y: Double) -> Bool {
    let dx = (x - CX) / 66, dy = (y - CY) / 80
    return dx * dx + dy * dy < 1 && x > coast(y) + 1
}

struct District {
    let id: String, name: String, x: Double, y: Double, ang: Double, step: Double
    var curvy = false, dim = 1.0, sparse = false
    let mix: [(String, Double)]
}

let DISTRICTS: [District] = [
    District(id: "core", name: "CORE", x: 52, y: 60, ang: 0, step: 2.6, mix: [("corpo-block", 0.75), ("block", 0.25)]),
    District(id: "foundry", name: "FOUNDRY", x: 46, y: 18, ang: 0.21, step: 3.4, mix: [("industrial-block", 0.8), ("port-block", 0.2)]),
    District(id: "docks", name: "DOCKS", x: 22, y: 34, ang: -0.35, step: 3.4, mix: [("port-block", 0.7), ("industrial-block", 0.3)]),
    District(id: "bazaar", name: "BAZAAR", x: 66, y: 30, ang: 0.52, step: 2.4, mix: [("market-block", 0.7), ("residential-block", 0.3)]),
    District(id: "heights", name: "HEIGHTS", x: 84, y: 48, ang: -0.6, step: 3.2, curvy: true,
             mix: [("luxury-block", 0.8), ("corpo-block", 0.2)]),
    District(id: "sprawl", name: "SPRAWL", x: 58, y: 94, ang: 0.14, step: 2.7,
             mix: [("residential-block", 0.6), ("market-block", 0.15), ("block", 0.25)]),
    District(id: "smelter", name: "SMELTER", x: 86, y: 90, ang: 0, step: 3.6, mix: [("industrial-block", 0.85), ("market-block", 0.15)]),
    District(id: "riviera", name: "RIVIERA", x: 26, y: 100, ang: 0.78, step: 3.1, curvy: true, dim: 0.6,
             mix: [("luxury-block", 0.5), ("market-block", 0.5)]),
    District(id: "wastes", name: "WASTES", x: 0, y: 0, ang: 0, step: 6, sparse: true, mix: [("badlands-block", 1)]),
]
let DIST: [String: District] = Dictionary(uniqueKeysWithValues: DISTRICTS.map { ($0.id, $0) })
let TINT: [String: UInt32] = ["core": 0x9fe8ff, "foundry": 0xffb547, "docks": 0x3fd6c4, "bazaar": 0xff4fd8, "heights": 0x62f0d8,
                              "sprawl": 0xff7ab8, "smelter": 0xff8a3d, "riviera": 0xb38bff, "wastes": 0xc8a070]
let REPO_HOME: [String: String] = ["claude-agent-hub": "core", "santinel": "foundry", "dolya": "docks", "project-estimator": "sprawl",
                                   "personal-fin-assistant": "heights", "raft-ceo-workspace": "bazaar"]
let SPARE = ["bazaar", "sprawl", "heights", "smelter", "riviera", "docks", "foundry", "core"]

func regionOf(_ x: Double, _ y: Double) -> String? {
    if !inWorld(x, y) { return nil }
    if !inCity(x, y) { return "wastes" }
    var best: String? = nil, bd = Double.infinity
    for d in DISTRICTS where d.id != "wastes" {
        let dx = x - d.x, dy = y - d.y
        let dd = dx * dx + dy * dy * 0.8
        if dd < bd { bd = dd; best = d.id }
    }
    return best
}

// ---- street graph ------------------------------------------------------------------------------------------------
struct Edge { let to: Int; let len: Double; let hw: Bool }
final class GNode {
    let id: Int, x: Double, y: Double, d: String, hw: Bool
    var adj: [Edge] = []
    init(id: Int, x: Double, y: Double, d: String, hw: Bool) { self.id = id; self.x = x; self.y = y; self.d = d; self.hw = hw }
}
final class Lot {
    var idx = 0
    let x: Double, y: Double, d: String, size: Double, quad: [Int], tall: Double
    let flip: Bool, scale: Double, sprite: String, h: UInt32
    var landmark = false, owner = false
    init(x: Double, y: Double, d: String, size: Double, quad: [Int], tall: Double, flip: Bool, scale: Double,
         sprite: String, h: UInt32) {
        self.x = x; self.y = y; self.d = d; self.size = size; self.quad = quad; self.tall = tall
        self.flip = flip; self.scale = scale; self.sprite = sprite; self.h = h
    }
}

func pickMix(_ mix: [(String, Double)], _ r: Double) -> String {
    var acc = 0.0
    for (n, p) in mix { acc += p; if r < acc { return n } }
    return mix[0].0
}

/// The built city. Immutable after init, so the static renderer may read it from a background queue.
final class CityModel {
    private(set) var nodes: [GNode] = []
    private(set) var lots: [Lot] = []
    private(set) var owner: Lot!
    private(set) var holos: [Lot] = []
    private var grid: [Int64: [Int]] = [:]   // spatial hash, 6 units
    /// world, city and water outlines in world units
    private(set) var world: [(Double, Double)] = [], city: [(Double, Double)] = [], water: [(Double, Double)] = []
    /// street segments as node-id pairs, local streets and highways, each edge once (to.id > n.id)
    private(set) var streets: [(Int, Int)] = [], highways: [(Int, Int)] = []

    init() {
        buildCity()
        shapes()
        for n in nodes { for e in n.adj where e.to > n.id { if e.hw { highways.append((n.id, e.to)) } else { streets.append((n.id, e.to)) } } }
    }

    private func addNode(_ x: Double, _ y: Double, _ d: String, _ hw: Bool = false) -> GNode {
        let n = GNode(id: nodes.count, x: x, y: y, d: d, hw: hw)
        nodes.append(n)
        return n
    }
    private func link(_ a: GNode, _ b: GNode, _ hw: Bool = false) {
        if a === b || a.adj.contains(where: { $0.to == b.id }) { return }
        let len = jsHypot(a.x - b.x, a.y - b.y)
        a.adj.append(Edge(to: b.id, len: len, hw: hw))
        b.adj.append(Edge(to: a.id, len: len, hw: hw))
    }
    private func cellKey(_ gx: Int, _ gy: Int) -> Int64 { Int64(gx) << 32 | Int64(UInt32(bitPattern: Int32(gy))) }
    private func index(_ n: GNode) {
        grid[cellKey(Int(floor(n.x / 6)), Int(floor(n.y / 6))), default: []].append(n.id)
    }
    func nearest(_ x: Double, _ y: Double, _ r: Double = 12, _ pred: ((GNode) -> Bool)? = nil) -> GNode? {
        var best: GNode? = nil, bd = r * r
        var gx = Int(floor((x - r) / 6))
        while gx <= Int(floor((x + r) / 6)) {
            var gy = Int(floor((y - r) / 6))
            while gy <= Int(floor((y + r) / 6)) {
                for id in grid[cellKey(gx, gy)] ?? [] {
                    let n = nodes[id], dx = n.x - x, dy = n.y - y, dd = dx * dx + dy * dy
                    if dd < bd && (pred == nil || pred!(n)) { bd = dd; best = n }
                }
                gy += 1
            }
            gx += 1
        }
        return best
    }

    private func buildCity() {
        let rand = Mulberry(20771)
        for d in DISTRICTS {
            var order: [(Int, Int, GNode)] = [], cells: [Int: GNode] = [:]
            let K = Int(ceil(90 / d.step)), c = cos(d.ang), s = sin(d.ang)
            let ox = d.id == "wastes" ? CX : d.x, oy = d.id == "wastes" ? CY : d.y
            let ck = { (i: Int, j: Int) in (i + 1000) * 4000 + (j + 1000) }
            for i in -K...K {
                for j in -K...K {
                    var u = Double(i) * d.step, v = Double(j) * d.step
                    if d.curvy { u += sin(Double(j) * 0.7) * d.step * 0.35; v += cos(Double(i) * 0.6) * d.step * 0.35 }
                    let x = ox + u * c - v * s, y = oy + u * s + v * c
                    if regionOf(x, y) != d.id { continue }
                    let n = addNode(x, y, d.id)
                    cells[ck(i, j)] = n
                    order.append((i, j, n))
                }
            }
            for (i, j, n) in order {
                let r = cells[ck(i + 1, j)], b = cells[ck(i, j + 1)], rb = cells[ck(i + 1, j + 1)]
                let keep = d.sparse ? 0.55 : 1
                if let r, rand() < keep { link(n, r) }
                if let b, rand() < keep { link(n, b) }
                if let r, let b, let rb {
                    // `!(d.sparse && rand() < 0.7) && !(rand() < (d.sparse ? 0.2 : 0.07))`, short-circuit and all
                    if d.sparse && rand() < 0.7 { continue }
                    if rand() < (d.sparse ? 0.2 : 0.07) { continue }   // an empty lot now and then
                    let core = d.id == "core"
                    let tall = d.sparse ? 0.3 : (core ? 1.2 : 0.4) + rand() * (core ? 2.6 : 1.1)
                    let flip = rand() < 0.5
                    let scale = 0.85 + rand() * 0.25
                    let sprite = pickMix(d.mix, rand())
                    lots.append(Lot(x: (n.x + r.x + b.x + rb.x) / 4, y: (n.y + r.y + b.y + rb.y) / 4, d: d.id, size: d.step,
                                    quad: [n.id, r.id, rb.id, b.id], tall: tall, flip: flip, scale: scale,
                                    sprite: sprite, h: jsHash("\(i),\(j)" + d.id)))
                }
            }
        }
        nodes.forEach(index)
        // stitch district borders: a dangling node joins the nearest node of another district
        for n in nodes where n.adj.count < 3 {
            if let m = nearest(n.x, n.y, 5, { $0.d != n.d }) { link(n, m) }
        }
        // highways: a ring round the core, a curved radial to each district, the coast road, two exits into the desert
        var hwNodes: [GNode] = []
        func road(_ pts: [(Double, Double)]) {
            var prev: GNode? = nil
            for (x, y) in pts {
                if !inWorld(x, y) { prev = nil; continue }
                let n = addNode(x, y, regionOf(x, y) ?? "wastes", true)
                hwNodes.append(n)
                if let prev { link(prev, n, true) }
                prev = n
            }
        }
        var ring: [(Double, Double)] = []
        for k in 0...36 { let a = Double(k) / 36 * Double.pi * 2; ring.append((CX - 2 + cos(a) * 21, CY - 4 + sin(a) * 26)) }
        road(ring)
        for d in DISTRICTS where d.id != "core" && d.id != "wastes" {
            var pts: [(Double, Double)] = []
            let bx = (CX + d.x) / 2 + (d.y - CY) * 0.18, by = (CY + d.y) / 2 - (d.x - CX) * 0.18
            for k in 0...14 {
                let t = Double(k) / 14, u = 1 - t
                pts.append((u * u * CX + 2 * u * t * bx + t * t * d.x, u * u * CY + 2 * u * t * by + t * t * d.y))
            }
            road(pts)
        }
        var coastal: [(Double, Double)] = []
        var cy = 2.0; while cy <= 128 { coastal.append((coast(cy) + 4, cy)); cy += 3.5 }
        road(coastal)
        var east: [(Double, Double)] = []
        var ex = 70.0; while ex <= 125 { east.append((ex, 70 + sin(ex / 9) * 6)); ex += 4 }
        road(east)
        var south: [(Double, Double)] = []
        var sy = 100.0; while sy <= 148 { south.append((60 + sin(sy / 7) * 5, sy)); sy += 4 }
        road(south)
        for (k, n) in hwNodes.enumerated() where k % 2 == 0 {
            if let m = nearest(n.x, n.y, 7, { !$0.hw }) { link(n, m) }
        }
        hwNodes.forEach(index)
        lots = lots.filter { l in !hwNodes.contains { jsHypot($0.x - l.x, $0.y - l.y) < l.size * 0.55 } }   // cleared under a highway
        for (i, l) in lots.enumerated() { l.idx = i }
        owner = lots.reduce(lots[0]) { a, b in
            jsHypot(a.x - CX, a.y - CY) < jsHypot(b.x - CX, b.y - CY) ? a : b
        }
        // JS reduce without an initial value starts from lots[0] and compares it with lots[1]; reduce(lots[0]) compares
        // lots[0] with itself first, which keeps lots[0] (a < a is false, so b = lots[0]) — the same result.
        owner.owner = true
        holos = Array(lots.filter { ($0.d == "core" || $0.d == "bazaar") && $0.h % 11 == 0 }.prefix(5))
        // a few sprite landmarks per district, never next to each other; every other lot is drawn as a schematic block
        var marks: [Lot] = []
        let sorted = lots.enumerated().sorted { $0.element.h != $1.element.h ? $0.element.h < $1.element.h : $0.offset < $1.offset }
        for (_, l) in sorted {
            if l.owner || l.h % 5 != 0 { continue }
            if marks.contains(where: { jsHypot($0.x - l.x, $0.y - l.y) < 11 }) { continue }
            l.landmark = true
            marks.append(l)
        }
    }

    private func shapes() {   // outlines of the world, the city and the water, in world units
        for k in 0..<160 {
            let a = Double(k) / 160 * Double.pi * 2
            var r = 1.0
            while r > 0 && !inWorld(CX + cos(a) * 66 * r, CY + sin(a) * 80 * r) { r -= 0.01 }
            world.append((CX + cos(a) * 66 * r, CY + sin(a) * 80 * r))
            var q = 1.0
            while q > 0 && !inCity(CX + cos(a) * 50 * q, CY + sin(a) * 66 * q) { q -= 0.01 }
            city.append((CX + cos(a) * 50 * q, CY + sin(a) * 66 * q))
        }
        var y = -4.0
        while y <= 134 { water.append((coast(y), y)); y += 2 }   // a bay along the coast, not the whole west
        y = 134
        while y >= -4 { water.append((coast(y) - 18 - 4 * sin(y / 9), y)); y -= 2 }
    }
}

// ---- repositories to districts, hubs to lots ------------------------------------------------------------------------

/// repo -> district, in first-seen order (the page's `repoDistrict` Map).
final class RepoDistricts {
    private(set) var pairs: [(repo: String, district: String)] = []
    func districtFor(_ repo: String?) -> String {
        guard let repo, !repo.isEmpty else { return "wastes" }
        if let hit = pairs.first(where: { $0.repo == repo }) { return hit.district }
        let used = Set(pairs.map { $0.district })
        let d: String
        if let home = REPO_HOME[repo], !used.contains(home) { d = home }
        else { d = SPARE.first(where: { !used.contains($0) }) ?? SPARE[Int(jsHash(repo) % UInt32(SPARE.count))] }
        pairs.append((repo, d))
        return d
    }
    /// district -> repo, the later repo winning like `new Map([...repoDistrict].map(([r, d]) => [d, r]))`
    var byDistrict: [String: String] { var m: [String: String] = [:]; for p in pairs { m[p.district] = p.repo }; return m }
}

/// A hub's placement request: its stage name, its current lot (nil = needs one) and its district.
protocol Placeable: AnyObject {
    var stage: String { get }
    var lot: Lot? { get set }
    var district: String { get set }
}

/// Each district's hubs take its lots nearest the district's seed, a lot apart; a full district spills over.
/// `towers` in insertion order; `repoOf` gives the stage's repo.
func placeHubs(_ city: CityModel, _ towers: [Placeable], _ repos: RepoDistricts, _ repoOf: (Placeable) -> String?) {
    var taken: [Lot] = [city.owner]
    var takenSet = Set<Int>([city.owner.idx])
    for tw in towers { if let l = tw.lot, !takenSet.contains(l.idx) { taken.append(l); takenSet.insert(l.idx) } }
    for tw in towers where tw.lot == nil {
        let did = repos.districtFor(repoOf(tw))
        let seed: (x: Double, y: Double) = did == "wastes" ? (CX + 34, CY + 30) : (DIST[did]!.x, DIST[did]!.y)
        func free(_ gap: Double, _ d: String?) -> [Lot] {
            city.lots.filter { l in (d == nil || l.d == d!) && !takenSet.contains(l.idx) &&
                !taken.contains { jsHypot($0.x - l.x, $0.y - l.y) < gap } }
        }
        var pool = free(9.5, did)
        if pool.isEmpty { pool = free(6, did) }
        if pool.isEmpty { pool = free(4, did) }
        if pool.isEmpty { pool = free(4, nil) }
        pool = pool.enumerated().sorted { a, b in
            let da = jsHypot(a.element.x - seed.x, a.element.y - seed.y), db = jsHypot(b.element.x - seed.x, b.element.y - seed.y)
            return da != db ? da < db : a.offset < b.offset
        }.map { $0.element }
        let h = jsHash(tw.stage)
        let lot = pool.isEmpty ? city.lots[Int(h % UInt32(city.lots.count))] : pool[min(pool.count - 1, Int(h % 3))]
        tw.lot = lot
        tw.district = lot.d
        if !takenSet.contains(lot.idx) { taken.append(lot); takenSet.insert(lot.idx) }
    }
}
