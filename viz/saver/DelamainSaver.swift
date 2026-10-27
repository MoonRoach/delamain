// Delamain Live: a native screen saver drawing the hub-viz city (viz.html) with Core Animation, no WebKit.
// The static city is a Core Graphics bitmap rendered for the camera's target view at full backing resolution;
// towers, cabs, traffic, beams, labels, rain and the HUD are screen-space layers moved every frame.
// The hub-viz server must be running (see ../README.md); until data arrives the view says what it waits for.
// Settings are the dev.delamain.saver defaults suite: server, follow, replayAfter, lang, diagnostics.
import AppKit
import IOKit.pwr_mgt
import QuartzCore
import ScreenSaver

// ---- layer plumbing -----------------------------------------------------------------------------------------------
final class NoAnim: NSObject, CALayerDelegate {
    static let shared = NoAnim()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}
func mk<T: CALayer>(_ l: T, _ parent: CALayer? = nil) -> T {
    l.delegate = NoAnim.shared
    parent?.addSublayer(l)
    return l
}
func radial(_ parent: CALayer?) -> CAGradientLayer {
    let g = mk(CAGradientLayer(), parent)
    g.type = .radial
    g.startPoint = CGPoint(x: 0.5, y: 0.5)
    g.endPoint = CGPoint(x: 1, y: 1)
    return g
}
func setGlow(_ g: CAGradientLayer, _ c: RGB) {
    if (g.value(forKey: "rgb") as? UInt32) != c.key {
        g.colors = [c.cg(1), c.cg(0)]
        g.setValue(c.key, forKey: "rgb")
    }
}
/// place a glow of radius r at p with peak alpha a
func placeGlow(_ g: CAGradientLayer, _ p: CGPoint, _ r: Double, _ a: Double) {
    guard r > 0 else { g.isHidden = true; return }
    g.isHidden = false
    g.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
    g.position = p
    g.opacity = Float(max(0, min(1, a)))
}

/// A text layer that re-measures only when its text or size changes; positioned by its baseline.
final class TextL: CATextLayer {
    var text = "", fsize: CGFloat = 0, measured = CGSize.zero, ascent: CGFloat = 0
    var weight: NSFont.Weight = .regular
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    func set(_ s: String, _ size: CGFloat) {
        let size = (size * 2).rounded() / 2   // half-point steps: a zooming label is not re-rasterised every frame for nothing
        if s == text && size == fsize { return }
        text = s; fsize = size
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        font = f; fontSize = size; string = s
        measured = (s as NSString).size(withAttributes: [.font: f])
        ascent = f.ascender
        bounds = CGRect(x: 0, y: 0, width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
    }
    /// align: 0 left, 0.5 centre
    func place(_ x: CGFloat, baseline y: CGFloat, align: CGFloat) {
        anchorPoint = CGPoint(x: align, y: 0)
        position = CGPoint(x: x, y: y - ascent - 1)
    }
}
func text(_ parent: CALayer, scale: CGFloat, color: CGColor, align: CATextLayerAlignmentMode = .center) -> TextL {
    let t = mk(TextL(), parent)
    t.contentsScale = scale
    t.foregroundColor = color
    t.alignmentMode = align
    return t
}

// ---- model ---------------------------------------------------------------------------------------------------------
class Entity {
    enum Kind { case hub, cab, owner }
    let key: String, kind: Kind
    var label: String
    var pulse = 0.0
    var color: RGB
    init(key: String, kind: Kind, label: String, color: RGB) { self.key = key; self.kind = kind; self.label = label; self.color = color }
}

final class Tower: Entity, Placeable {
    var stage = "", lot: Lot? = nil, district = "", title = "", open = true
    var layers: TowerLayers?
}

final class Cab: Entity {
    var stage = "", role = "", engine = "", model = "", title = ""
    var working = false
    weak var home: Tower?
    var p = 0.0, alt = 0.0, vx = 0.0, vy = 0.0
    var wp: (Double, Double)?
    var x = 0.0, y = 0.0, z = 0.0, px = 0.0, py = 0.0
    var trail: [(x: Double, y: Double, z: Double, t: Double)] = []
    var layers: CabLayers?
}

final class StageM {
    let name: String
    var open = true, repo = ""
    var workers: [String: Cab] = [:]
    var hub: Tower!
    init(name: String, repo: String) { self.name = name; self.repo = repo }
}

final class Npc {
    var a: GNode, b: GNode, t = 1.0, speed: Double, hwLover: Bool, x: Double, y: Double
    var dir = (1.0, 0.0)
    var trail: [(x: Double, y: Double, t: Double)] = []
    var layer: CALayer!
    init(_ n: GNode, speed: Double, hwLover: Bool) { a = n; b = n; self.speed = speed; self.hwLover = hwLover; x = n.x; y = n.y }
}

struct Flyer { let rx: Double, ry: Double, v: Double, p: Double, alt: Double; var layer: CALayer? }

struct Beam { let a: Entity, b: Entity, t0: Double, dur: Double, color: RGB; var hit = false; let line: CAShapeLayer; let head: CAGradientLayer }
struct Ripple { let at: () -> CGPoint; let t0: Double; let color: RGB; let layer: CAShapeLayer }
struct FloatLabel { let who: Entity; let text: String; let t0: Double; let group: CALayer; let bg: CALayer; let bar: CALayer; let txt: TextL }

final class TowerLayers {
    let group: CALayer, glow: CAGradientLayer, sprite: CALayer, beacon: CAGradientLayer
    var sign: TextL?
    init(_ parent: CALayer) {
        group = mk(CALayer(), parent)
        glow = radial(group)
        sprite = mk(CALayer(), group)
        beacon = radial(group)
    }
    func remove() { group.removeFromSuperlayer(); sign?.removeFromSuperlayer() }
}

final class CabLayers {
    let group: CALayer, shadow: CALayer, trail: CAShapeLayer, glow: CAGradientLayer, sprite: CALayer, label: TextL
    var tint: UInt32 = 0
    init(_ parent: CALayer, scale: CGFloat) {
        group = mk(CALayer(), parent)
        shadow = mk(CALayer(), group)
        shadow.backgroundColor = CGColor(gray: 0, alpha: 0.35)
        trail = mk(CAShapeLayer(), group)
        trail.fillColor = nil; trail.lineCap = .round; trail.lineJoin = .round; trail.contentsScale = scale
        glow = radial(group)
        sprite = mk(CALayer(), group)
        label = text(group, scale: scale, color: Pal.ink.cg())
    }
    func remove() { group.removeFromSuperlayer() }
}

// ---- settings ----------------------------------------------------------------------------------------------------------
/// The dev.delamain.saver defaults. legacyScreenSaver is sandboxed, so the suite may resolve to the container's plist
/// rather than ~/Library/Preferences; the real file (the real home, not the container's NSHomeDirectory) is the fallback.
struct Prefs {
    private let suite = UserDefaults(suiteName: "dev.delamain.saver")
    private let file: [String: Any] = {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return [:] }
        let url = URL(fileURLWithPath: String(cString: dir)).appendingPathComponent("Library/Preferences/dev.delamain.saver.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [:] }
        return plist as? [String: Any] ?? [:]
    }()
    func object(_ key: String) -> Any? { suite?.object(forKey: key) ?? file[key] }
    func string(_ key: String) -> String? { object(key) as? String }
    func bool(_ key: String) -> Bool? { (object(key) as? NSNumber)?.boolValue }
    func number(_ key: String) -> Double? { (object(key) as? NSNumber)?.doubleValue }
}

// ---- the view -------------------------------------------------------------------------------------------------------
@objc(DelamainSaverView)
final class DelamainSaverView: ScreenSaverView {
    private let city = CityModel()
    private var sprites: Sprites!
    private var feed: Feed!
    private let serverURL: URL
    private let follow: Bool
    private let diagnostics: Bool   // report fps and layout with each /state poll, and dump one frame as PNG

    // model
    private var machineName = "", online = false
    private var stages: [String: StageM] = [:]
    private var towerOrder: [String] = [], towers: [String: Tower] = [:]   // insertion order matters for placement
    private var cabs: [String: Cab] = [:]
    private let owner = Tower(key: "owner", kind: .owner, label: "owner", color: Pal.gold)
    private let repos = RepoDistricts()
    private var beams: [Beam] = [], ripples: [Ripple] = [], labels: [FloatLabel] = []
    private var npcs: [Npc] = [], flyers: [Flyer] = []
    private var rain: [(Double, Double, Double)] = []
    private var tickerRows: [(at: String, stage: String, rest: String, replayed: Bool)] = []
    private var replayEvent: Event?

    // camera
    private var W = 0.0, H = 0.0, K = 4.0, BASE = (x: 0.0, y: 0.0), backing: CGFloat = 2
    private var cam = (x: 0.0, y: 0.0, z: 1.0, tx: 0.0, ty: 0.0, tz: 1.0, until: 0.0)
    private var camInit = false

    // layers
    private let scene = CALayer()
    private var backdrop: CAGradientLayer!, skyLayer: CALayer!
    private var overview: (img: StaticImage, layer: CALayer, dash: CAShapeLayer)?
    private var detail: (img: StaticImage, layer: CALayer, dash: CAShapeLayer)?
    private var staticGroup: CALayer!, npcGroup: CALayer!, npcTrails: CAShapeLayer!, towerGroup: CALayer!, nameGroup: CALayer!
    private var holoGroup: CALayer!, signGroup: CALayer!, cabGroup: CALayer!, flyerGroup: CALayer!, beamGroup: CALayer!
    private var rippleGroup: CALayer!, labelGroup: CALayer!, rainLayer: CAShapeLayer!, hudGroup: CALayer!
    private var names: [(d: District, name: TextL, repo: TextL)] = []
    private var wastes: (TextL, TextL)!
    private var holoLayers: [CALayer] = []
    private var hudBrand: TextL!, hudSub: TextL!, hudMode: TextL!, hudLegend: TextL!
    private var tickerBg: CAGradientLayer!, tickerBar: CALayer!, tickerText: [TextL] = []
    private var status: TextL!

    // static rendering
    private let renderQueue = DispatchQueue(label: "dev.delamain.saver.static", qos: .userInitiated)
    private var renderingOverview = false, renderingDetail = false
    private var excludedKey: [Int] = [], excludedChangedAt = 0.0
    private var lastStaticMs = 0.0
    private var detailTarget: [Double] = [], detailTargetAt = 0.0

    // clock and diagnostics
    private var link: AnyObject?
    private var lastLinkTick = 0.0, last = 0.0, started = 0.0
    private var fpsFrames = 0, fpsSince = 0.0, measuredFPS = 0.0
    private var frameWritten = false
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private static var made = 0
    private let instance: Int = { DelamainSaverView.made += 1; return DelamainSaverView.made }()

    override init?(frame: NSRect, isPreview: Bool) {
        let prefs = Prefs()
        serverURL = prefs.string("server").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8765")!
        follow = prefs.bool("follow") ?? true
        diagnostics = prefs.bool("diagnostics") ?? false
        let quiet = prefs.number("replayAfter")   // nil: live only
        Strings.current = Strings.resolve(prefs.string("lang"))
        super.init(frame: frame, isPreview: isPreview)
        sprites = Sprites(bundle: Bundle(for: DelamainSaverView.self))
        feed = Feed(base: serverURL, quietSeconds: quiet)
        animationTimeInterval = 1.0 / 30
        wantsLayer = true
        layer?.backgroundColor = RGB(0x030409).cg()
        setupLayers()
        setupAmbient()
        wireFeed()
        relayout()
        showStatus(Strings.current.connecting(serverURL.absoluteString))
    }

    required init?(coder: NSCoder) { return nil }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    // ---- lifecycle ----------------------------------------------------------------------------------------------------
    // While the saver runs it keeps the display on, as a video player does; without it the display sleeps under the
    // saver (an owner who keeps the display awake with `caffeinate -d` blocks the saver from ever starting).
    private var displayAwake: IOPMAssertionID = 0

    override func startAnimation() {
        super.startAnimation()
        guard !running else { return }
        running = true
        if !isPreview && displayAwake == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Delamain Live screen saver" as CFString, &displayAwake)
        }
        started = nowMs(); last = started; fpsSince = started; fpsFrames = 0
        feed.start()
        if #available(macOS 14.0, *) {
            let dl = displayLink(target: self, selector: #selector(linkTick(_:)))
            dl.add(to: .main, forMode: .common)
            link = dl
        }
        // legacyScreenSaver may never call stopAnimation on macOS 14+, and old instances keep running: stop on the engine's word
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main) { [weak self] _ in
            self?.halt()
        })
    }

    override func stopAnimation() {
        halt()
        super.stopAnimation()
    }

    private func halt() {
        guard running else { return }
        running = false
        if displayAwake != 0 { IOPMAssertionRelease(displayAwake); displayAwake = 0 }
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    @available(macOS 14.0, *)
    @objc private func linkTick(_ l: CADisplayLink) {
        lastLinkTick = nowMs()
        step()
    }

    override func animateOneFrame() {
        // the display link drives frames when it runs; the host's timer is the fallback
        if nowMs() - lastLinkTick > 250 { step() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { halt() }   // the host dropped the view without stopAnimation: do not keep the display awake
        relayout()
    }
    deinit { if displayAwake != 0 { IOPMAssertionRelease(displayAwake) } }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); relayout() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); relayout() }

    // ---- layers --------------------------------------------------------------------------------------------------------
    private var laidOut = false
    private func setupLayers() {
        guard let root = layer else { return }
        defer { laidOut = true }
        _ = mk(scene, root)
        scene.isGeometryFlipped = true   // canvas coordinates: origin top-left, y down
        backdrop = mk(CAGradientLayer(), scene)
        backdrop.colors = [RGB(0x030409).cg(), RGB(0x0a0716).cg(), RGB(0x05040b).cg()]
        backdrop.locations = [0, 0.5, 1]
        backdrop.startPoint = CGPoint(x: 0.5, y: 0); backdrop.endPoint = CGPoint(x: 0.5, y: 1)
        skyLayer = mk(CALayer(), scene)
        skyLayer.contents = sprites.sky
        skyLayer.opacity = 0.5
        staticGroup = mk(CALayer(), scene)
        npcTrails = mk(CAShapeLayer(), scene)
        npcTrails.fillColor = nil; npcTrails.strokeColor = Pal.red.cg(0.55 * 0.55 * 0.5); npcTrails.lineCap = .round
        npcGroup = mk(CALayer(), scene)
        towerGroup = mk(CALayer(), scene)
        nameGroup = mk(CALayer(), scene)
        holoGroup = mk(CALayer(), scene)
        signGroup = mk(CALayer(), scene)
        cabGroup = mk(CALayer(), scene)
        flyerGroup = mk(CALayer(), scene)
        beamGroup = mk(CALayer(), scene)
        rippleGroup = mk(CALayer(), scene)
        labelGroup = mk(CALayer(), scene)
        rainLayer = mk(CAShapeLayer(), scene)
        rainLayer.fillColor = nil; rainLayer.strokeColor = RGB(160, 180, 255).cg(0.07); rainLayer.lineWidth = 1
        hudGroup = mk(CALayer(), scene)

        for d in DISTRICTS where d.id != "wastes" {
            names.append((d, text(nameGroup, scale: 2, color: RGB(138, 150, 166).cg(0.35)), text(nameGroup, scale: 2, color: RGB(223, 230, 238).cg(0.65))))
        }
        wastes = (text(nameGroup, scale: 2, color: RGB(255, 181, 71).cg(0.45)), text(nameGroup, scale: 2, color: RGB(255, 181, 71).cg(0.45)))
        for _ in city.holos {
            let h = mk(CALayer(), holoGroup)
            h.contents = sprites.images["holo"]
            holoLayers.append(h)
        }
        hudBrand = text(hudGroup, scale: 2, color: Pal.magenta.cg(), align: .left)
        hudSub = text(hudGroup, scale: 2, color: Pal.dim.cg(), align: .left)
        hudMode = text(hudGroup, scale: 2, color: Pal.cyan.cg(), align: .right)
        hudLegend = text(hudGroup, scale: 2, color: Pal.dim.cg(), align: .right)
        tickerBg = mk(CAGradientLayer(), hudGroup)
        tickerBg.colors = [RGB(3, 4, 9).cg(0.85), RGB(3, 4, 9).cg(0)]
        tickerBg.startPoint = CGPoint(x: 0, y: 0.5); tickerBg.endPoint = CGPoint(x: 1, y: 0.5)
        tickerBar = mk(CALayer(), hudGroup)
        tickerBar.backgroundColor = Pal.magenta.cg(0.5)
        for _ in 0..<6 { tickerText.append(text(hudGroup, scale: 2, color: Pal.ink.cg(), align: .left)) }
        status = text(hudGroup, scale: 2, color: RGB(255, 79, 217).cg())
    }

    private func setupAmbient() {
        let r = Mulberry(7)
        for _ in 0..<90 {   // newNpc(r): the same draws in the same order as the page
            let n = city.nodes[Int(floor(r() * Double(city.nodes.count)))]
            let speed = 2 + r() * 2.5, hwLover = r() < 0.45
            _ = r() < 0.4 ? 0 : r() < 0.5 ? 1 : 2   // the page's colour draw; ambient cars are drawn grey
            let c = Npc(n, speed: speed, hwLover: hwLover)
            let body = mk(CALayer(), npcGroup)
            let shell = mk(CALayer(), body); shell.name = "shell"
            shell.backgroundColor = RGB(0x5a6070).cg(0.55 * 0.8)
            let head = mk(CAGradientLayer(), body); head.name = "head"
            head.colors = [RGB(0xfff6d8).cg(0.55 * 0.4), RGB(0xfff6d8).cg(0)]
            head.startPoint = CGPoint(x: 0, y: 0.5); head.endPoint = CGPoint(x: 1, y: 0.5)
            let tail = mk(CALayer(), body); tail.name = "tail"
            tail.backgroundColor = Pal.red.cg(0.55)
            c.layer = body
            npcs.append(c)
        }
        for _ in 0..<3 {
            var f = Flyer(rx: 20 + r() * 30, ry: 25 + r() * 35, v: 0.03 + r() * 0.05, p: r() * 10, alt: 12 + r() * 10, layer: nil)
            let l = mk(CALayer(), flyerGroup)
            l.contents = sprites.images["flyer"]
            l.opacity = 0.4
            f.layer = l
            flyers.append(f)
        }
        rain = (0..<180).map { _ in (Double.random(in: 0..<1), Double.random(in: 0..<1), 0.4 + Double.random(in: 0..<1) * 0.6) }
    }

    private func relayout() {
        guard laidOut else { return }   // setFrameSize runs inside super.init, before setupLayers
        let b = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let changed = Double(b.width) != W || Double(b.height) != H || scale != backing
        guard changed, b.width > 0, b.height > 0 else { return }
        W = Double(b.width); H = Double(b.height); backing = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.frame = b
        backdrop.frame = b
        rainLayer.frame = b; npcTrails.frame = b
        rainLayer.contentsScale = scale; npcTrails.contentsScale = scale
        func rescale(_ l: CALayer) { if l is CATextLayer || l is CAShapeLayer || l is CAGradientLayer { l.contentsScale = scale }; l.sublayers?.forEach(rescale) }
        rescale(scene)
        CATransaction.commit()
        fit()
        overview = nil; detail = nil
        staticGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        requestOverview()
    }

    private var hudScale: Double { isPreview ? max(0.45, min(1, W / 1200)) : 1 }

    // ---- camera and projection ----------------------------------------------------------------------------------------
    private func fit() {
        guard W > 0, !city.nodes.isEmpty else { return }
        var x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
        for n in city.nodes { let a = n.x - n.y, b = (n.x + n.y) * 0.5; x0 = min(x0, a); x1 = max(x1, a); y0 = min(y0, b); y1 = max(y1, b) }
        K = min((W - 60) / (x1 - x0), max(H * 0.5, H - 200) / (y1 - y0))   // a small preview keeps a positive scale
        BASE = ((x0 + x1) / 2, (y0 + y1) / 2)
        if !camInit { cam.x = BASE.x; cam.tx = BASE.x; cam.y = BASE.y; cam.ty = BASE.y; camInit = true }
    }
    @inline(__always) private func P(_ x: Double, _ y: Double, _ lift: Double = 0) -> CGPoint {
        let a = x - y, b = (x + y) * 0.5, u = K * cam.z
        return CGPoint(x: W / 2 + (a - cam.x) * u, y: H / 2 + 30 + (b - cam.y) * u - lift * u)
    }
    private var unit: Double { K * cam.z }

    private func focus(_ x: Double, _ y: Double) {   // the camera flies to where the city just spoke, then drifts back
        guard follow else { return }
        cam.tx = x - y; cam.ty = (x + y) * 0.5; cam.tz = 2.1; cam.until = nowMs() + 7000
    }
    private func moveCamera(_ now: Double, _ dt: Double) {
        if now > cam.until { cam.tx = BASE.x + sin(now / 23000) * 6; cam.ty = BASE.y + cos(now / 31000) * 4; cam.tz = 1 }
        let k = 1 - pow(0.25, dt)
        // the page's easing, plus a floor on the speed so the camera actually arrives: at rest the static layer
        // is shown 1:1 and stays pixel-crisp instead of being resampled a fraction of a percent off
        func ease(_ v: Double, _ t: Double, _ rate: Double, _ minSpeed: Double) -> Double {
            let d = t - v
            var s = d * k * rate
            let floor = minSpeed * dt
            if abs(s) < floor { s = abs(d) <= floor ? d : (d > 0 ? floor : -floor) }
            return v + s
        }
        cam.x = ease(cam.x, cam.tx, 0.6, 1.0)
        cam.y = ease(cam.y, cam.ty, 0.6, 1.0)
        cam.z = ease(cam.z, cam.tz, 0.5, 0.02 * cam.tz)
    }

    // ---- feed -----------------------------------------------------------------------------------------------------------
    private func wireFeed() {
        feed.onState = { [weak self] st in self?.applyState(st) }
        feed.onLine = { [weak self] ev, replayed in self?.onLine(ev, replayed) }
        feed.onOnline = { [weak self] on, err in
            guard let self else { return }
            self.online = on
            if !on, let err, !self.feed.stateSeen { self.showStatus(Strings.current.notAnswering(err)) }
            self.hud()
        }
        feed.onReplay = { [weak self] ev in self?.replayEvent = ev; self?.hud() }
        guard diagnostics else { return }
        feed.diagnostics = { [weak self] in
            guard let self else { return "saver=native" }
            return "saver=native&fps=\(String(format: "%.1f", self.measuredFPS))&layers=\(self.layerCount())&static_ms=\(Int(self.lastStaticMs))" +
                "&view=\(self.instance)&size=\(Int(self.W))x\(Int(self.H))@\(Int(self.backing))&preview=\(self.isPreview ? 1 : 0)" +
                "&win=\(self.window?.windowNumber ?? 0)&occl=\(self.window?.occlusionState.contains(.visible) == true ? "vis" : "hid")"
        }
    }

    private func showStatus(_ s: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        status.set(s, CGFloat(15 * hudScale))
        status.place(CGFloat(W / 2), baseline: CGFloat(H / 2), align: 0.5)
        status.isHidden = s.isEmpty
        CATransaction.commit()
    }

    private func layerCount() -> Int {
        func count(_ l: CALayer) -> Int { 1 + (l.sublayers?.reduce(0) { $0 + count($1) } ?? 0) }
        return count(scene)
    }

    private func keyOf(_ stage: String, _ role: String) -> String { role == "owner" ? "owner" : "\(machineName)|\(stage)|\(role)" }

    @discardableResult
    private func ensureStage(_ name: String, _ repo: String?) -> StageM {
        let st: StageM
        if let s = stages[name] { st = s } else { st = StageM(name: name, repo: repo ?? ""); stages[name] = st }
        if let repo, !repo.isEmpty, st.repo.isEmpty { st.repo = repo; if let hub = st.hub { hub.lot = nil; place() } }
        if st.hub == nil {
            let k = keyOf(name, "hub")
            let tw = towers[k] ?? { let t = Tower(key: k, kind: .hub, label: name, color: Pal.violet); t.stage = name; return t }()
            st.hub = tw
            if towers[k] == nil { towerOrder.append(k) }
            towers[k] = tw
            place()
        }
        return st
    }

    private func place() {
        placeHubs(city, towerOrder.compactMap { towers[$0] }, repos) { [weak self] tw in self?.stages[tw.stage]?.repo }
    }

    private func ensureWorker(_ stageName: String, _ w: Worker) {
        let st = ensureStage(stageName, nil)
        let c: Cab
        if let have = st.workers[w.role] { c = have } else {
            let k = keyOf(stageName, w.role), r = Mulberry(jsHash(k))
            c = Cab(key: k, kind: .cab, label: w.role, color: Pal.tool)
            c.stage = stageName; c.role = w.role
            c.home = st.hub
            c.alt = 8 + r() * 9; c.p = r() * 20
            let hl = st.hub.lot ?? city.owner!
            c.x = hl.x + (r() - 0.5) * 8; c.y = hl.y + (r() - 0.5) * 8
            fly(c, nowMs(), 0)
            st.workers[w.role] = c; cabs[k] = c
        }
        if let e = w.engine, !e.isEmpty { c.engine = e }
        c.model = w.model ?? ""; c.working = w.working ?? false; c.title = w.title ?? ""
        c.color = Pal.engine(c.engine)
    }

    private func applyState(_ s: State) {
        machineName = s.machine
        showStatus("")
        var seen = Set<String>()
        for sv in s.stages ?? [] {
            let st = ensureStage(sv.name, sv.repo)
            st.open = sv.open ?? true; seen.insert(sv.name)
            st.hub.title = (sv.hub?.title).flatMap { $0.isEmpty ? nil : $0 } ?? sv.goal ?? ""
            st.hub.open = st.open
            var roles = Set<String>()
            for w in sv.workers ?? [] where w.role != "hub" { ensureWorker(sv.name, w); roles.insert(w.role) }
            for (role, c) in st.workers where !roles.contains(role) { st.workers[role] = nil; cabs[c.key] = nil }   // its process ended
        }
        for (name, st) in stages where !seen.contains(name) {   // off the map at once: closed, or its hub sleeps
            for c in st.workers.values { cabs[c.key] = nil }
            if let hub = st.hub { towers[hub.key] = nil; towerOrder.removeAll { $0 == hub.key } }
            stages[name] = nil
        }
        hud()
    }

    private func resolve(_ pair: [String]) -> Entity? {
        guard pair.count >= 2 else { return nil }
        let stage = pair[0], role = pair[1]
        if role == "owner" { return owner }
        guard let st = stages[stage], let hub = st.hub else { return nil }
        if role == "hub" { return hub }
        return st.workers[role] ?? hub
    }

    private func worldOf(_ n: Entity) -> (Double, Double) {
        if let c = n as? Cab { return (c.x, c.y) }
        if n.kind == .owner { return (city.owner.x, city.owner.y) }
        if let t = n as? Tower, let l = t.lot { return (l.x, l.y) }
        return (CX, CY)
    }
    private let TOWER_STEP = 4.2   // hub towers keep one size in every district
    private func towerLift(_ n: Entity) -> Double { n.kind == .owner ? 7.5 : 6.4 * TOWER_STEP / 5.5 }
    private func anchor(_ n: Entity) -> CGPoint {
        if let c = n as? Cab { return P(c.x, c.y, c.z) }
        let (x, y) = worldOf(n)
        return P(x, y, towerLift(n))
    }

    private func onLine(_ ev: Event, _ replayed: Bool) {
        let now = nowMs()
        defer { tick(ev, replayed) }
        guard let from = resolve(ev.from) else { return }
        var tos: [Entity] = []
        for t in ev.to ?? [] { if let e = resolve(t), e !== from, !tos.contains(where: { $0 === e }) { tos.append(e) } }
        from.pulse = 1
        for to in tos { send(from, to, now) }
        if tos.isEmpty { addRipple({ [weak self, from] in self?.anchor(from) ?? .zero }, now, from.color) }
        let (fx, fy) = worldOf(from); focus(fx, fy)
        let t = short(ev.text, 72)   // a broadcast to every stage shows its line once
        if !labels.contains(where: { $0.text == t && now - $0.t0 < 3000 }) { addLabel(from, t, now) }
        if labels.count > 5 { let l = labels.removeFirst(); l.group.removeFromSuperlayer() }
    }

    private func short(_ s: String, _ k: Int) -> String { s.count > k ? String(s.prefix(k - 1)) + "…" : s }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dm: DateFormatter = { let f = DateFormatter(); f.dateFormat = Strings.current.dayMonth; return f }()

    private func tick(_ ev: Event, _ replayed: Bool) {
        let d = Feed.date(ev.at) ?? Date()
        let to = ev.to ?? []
        let who = to.isEmpty ? "" : " → " + to.map { $0.count >= 2 && $0[1] == "hub" && $0[0] != ev.stage ? "hub \($0[0])" : ($0.count >= 2 ? $0[1] : "") }
            .joined(separator: ", ")
        tickerRows.append((DelamainSaverView.hm.string(from: d), ev.stage, "\(ev.tag ?? "")\(who): \(short(ev.text, 140))", replayed))
        if tickerRows.count > 6 { tickerRows.removeFirst(tickerRows.count - 6) }
        layoutTicker()
    }

    // A cab wanders: it picks a point over the city (now and then one by its hub), turns towards it smoothly and flies
    // there at a steady speed, then picks the next one. A busy cab is only a little faster.
    private let CRUISE = 3.2
    private func waypoint(_ c: Cab) -> (Double, Double) {
        for _ in 0..<20 {
            let lot = c.home?.lot
            let near = Double.random(in: 0..<1) < 0.35 && lot != nil
            let x = near ? lot!.x + (Double.random(in: 0..<1) - 0.5) * 16 : CX + (Double.random(in: 0..<1) - 0.5) * 80
            let y = near ? lot!.y + (Double.random(in: 0..<1) - 0.5) * 16 : CY + (Double.random(in: 0..<1) - 0.5) * 110
            if inCity(x, y) { return (x, y) }
        }
        return (CX, CY)
    }

    private func fly(_ c: Cab, _ now: Double, _ dt: Double) {
        if c.wp == nil || jsHypot(c.wp!.0 - c.x, c.wp!.1 - c.y) < 2 { c.wp = waypoint(c) }
        let dx = c.wp!.0 - c.x, dy = c.wp!.1 - c.y, dd = jsHypot(dx, dy), d = dd == 0 ? 1 : dd
        let speed = CRUISE * (c.working ? 1.3 : 1), turn = min(1, dt * 0.9)
        c.vx += (dx / d * speed - c.vx) * turn; c.vy += (dy / d * speed - c.vy) * turn
        c.px = c.x; c.py = c.y
        c.x += c.vx * dt; c.y += c.vy * dt
        c.z = c.alt + sin(now / 2400 + c.p) * 1.2
    }

    private func send(_ from: Entity, _ to: Entity, _ now: Double) {   // every line is a beam between a spire and a cab
        let line = mk(CAShapeLayer(), beamGroup)
        line.fillColor = nil; line.lineWidth = 2; line.strokeColor = from.color.cg(0.75); line.contentsScale = backing
        line.lineCap = .round; line.lineJoin = .round
        let head = radial(beamGroup); head.contentsScale = backing
        setGlow(head, from.color)
        beams.append(Beam(a: from, b: to, t0: now, dur: 1400, color: from.color, line: line, head: head))
    }

    private func addRipple(_ at: @escaping () -> CGPoint, _ now: Double, _ color: RGB) {
        let l = mk(CAShapeLayer(), rippleGroup)
        l.fillColor = nil; l.lineWidth = 1.5; l.strokeColor = color.cg(0.7); l.contentsScale = backing
        ripples.append(Ripple(at: at, t0: now, color: color, layer: l))
    }

    private func addLabel(_ who: Entity, _ t: String, _ now: Double) {
        let g = mk(CALayer(), labelGroup)
        let bg = mk(CALayer(), g); bg.backgroundColor = RGB(6, 6, 16).cg(0.84)
        let bar = mk(CALayer(), g); bar.backgroundColor = who.color.cg()
        let tx = text(g, scale: backing, color: Pal.ink.cg(), align: .left)
        tx.set(t, 12)
        labels.append(FloatLabel(who: who, text: t, t0: now, group: g, bg: bg, bar: bar, txt: tx))
    }

    // ---- HUD -----------------------------------------------------------------------------------------------------------
    private func hud() {
        var nStages = 0, workers = 0, busy = 0
        for st in stages.values {
            if st.open { nStages += 1 }
            workers += st.workers.count
            busy += st.workers.values.filter(\.working).count
        }
        let name = machineName.isEmpty ? serverURL.host ?? "" : machineName
        let s = hudScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hudBrand.string = NSAttributedString(string: "DELAMAIN", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: CGFloat(16 * s), weight: .regular), .foregroundColor: Pal.magenta.ns(),
            .kern: CGFloat(16 * s * 0.38)])
        hudBrand.bounds = CGRect(x: 0, y: 0, width: 300 * s, height: 22 * s)
        hudBrand.anchorPoint = .zero
        hudBrand.position = CGPoint(x: 26 * s, y: 22 * s)
        hudSub.set("\(online ? "● " : "○ ")\(name)   ·   \(Strings.current.count(nStages, workers, busy))", CGFloat(13 * s))
        hudSub.anchorPoint = .zero
        hudSub.position = CGPoint(x: 26 * s, y: (22 + 22 + 5) * s)
        let right = CGFloat(W - 26 * s)
        let mf = NSFont.monospacedSystemFont(ofSize: CGFloat(13 * s), weight: .medium)
        let df = NSFont.monospacedSystemFont(ofSize: CGFloat(13 * s), weight: .regular)
        let para = NSMutableParagraphStyle(); para.alignment = .right; para.lineHeightMultiple = 1.1
        let mode = NSMutableAttributedString()
        if let ev = replayEvent, let d = Feed.date(ev.at) {
            mode.append(NSAttributedString(string: "REPLAY", attributes: [.font: mf, .foregroundColor: Pal.violet.ns(), .kern: CGFloat(13 * s * 0.2)]))
            mode.append(NSAttributedString(string: " · \(DelamainSaverView.dm.string(from: d)) \(DelamainSaverView.hm.string(from: d))\n\(Int(Feed.SPEED))× · \(Strings.current.lastHours(Int(Feed.REPLAY_HOURS)))",
                                           attributes: [.font: df, .foregroundColor: Pal.dim.ns()]))
        } else {
            mode.append(NSAttributedString(string: "LIVE", attributes: [.font: mf, .foregroundColor: Pal.cyan.ns(), .kern: CGFloat(13 * s * 0.2)]))
        }
        mode.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: mode.length))
        hudMode.string = mode
        hudMode.isWrapped = true
        hudMode.bounds = CGRect(x: 0, y: 0, width: 420 * s, height: 40 * s)
        hudMode.anchorPoint = CGPoint(x: 1, y: 0)
        hudMode.position = CGPoint(x: right, y: CGFloat(22 * s))
        // legend: coloured dots and names
        let lf = NSFont.monospacedSystemFont(ofSize: CGFloat(13 * s), weight: .regular)
        let legend = NSMutableAttributedString()
        for (c, n) in [(Pal.violet, Strings.current.hub), (Pal.amber, "claude"), (Pal.cyan, "codex"), (Pal.gold, "owner")] {
            legend.append(NSAttributedString(string: "   ●", attributes: [.font: lf, .foregroundColor: c.ns()]))
            legend.append(NSAttributedString(string: " \(n)", attributes: [.font: lf, .foregroundColor: Pal.dim.ns()]))
        }
        hudLegend.string = legend
        hudLegend.bounds = CGRect(x: 0, y: 0, width: 420 * s, height: 18 * s)
        hudLegend.anchorPoint = CGPoint(x: 1, y: 0)
        hudLegend.position = CGPoint(x: right, y: CGFloat(66 * s + (replayEvent != nil ? 18 * s : 0)))
        CATransaction.commit()
    }

    private func layoutTicker() {
        let s = hudScale, rowH = 13 * 1.35 * s, n = tickerRows.count
        let width = min(820 * s, W - 52 * s)
        let f = NSFont.monospacedSystemFont(ofSize: CGFloat(13 * s), weight: .regular)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let boxH = Double(n) * rowH + 20 * s
        let top = H - 22 * s - boxH
        tickerBg.isHidden = n == 0; tickerBar.isHidden = n == 0
        tickerBg.frame = CGRect(x: 26 * s, y: top, width: width, height: boxH)
        tickerBar.frame = CGRect(x: 26 * s, y: top, width: 2, height: boxH)
        for (i, t) in tickerText.enumerated() {
            guard i < n else { t.isHidden = true; continue }
            let r = tickerRows[i]
            let body = r.replayed ? RGB(0xaab4c0) : Pal.ink
            // ellipsis by hand: a monospaced row holds this many characters
            let cw = Double(("0" as NSString).size(withAttributes: [.font: f]).width)
            let room = max(8, Int((width - 24 * s) / max(1, cw)))
            var rest = r.rest
            let used = r.at.count + 1 + r.stage.count + 1
            if used + rest.count > room { rest = String(rest.prefix(max(0, room - used - 1))) + "…" }
            let a = NSMutableAttributedString(string: r.at, attributes: [.font: f, .foregroundColor: Pal.dim.ns()])
            a.append(NSAttributedString(string: " ", attributes: [.font: f]))
            a.append(NSAttributedString(string: r.stage, attributes: [.font: f, .foregroundColor: Pal.violet.ns()]))
            a.append(NSAttributedString(string: " " + rest, attributes: [.font: f, .foregroundColor: body.ns()]))
            t.isHidden = false
            t.string = a
            t.anchorPoint = .zero
            t.bounds = CGRect(x: 0, y: 0, width: width - 24 * s, height: rowH)
            t.position = CGPoint(x: 26 * s + 12 * s, y: top + 10 * s + Double(i) * rowH)
            t.opacity = Float(0.3 + 0.7 * Double(i + 1) / Double(n))
        }
        CATransaction.commit()
    }

    // ---- static layer ----------------------------------------------------------------------------------------------------
    private var pad: Double { max(W, H) * 0.08 }

    private func requestOverview() {
        guard W > 0, !renderingOverview else { return }
        let v = StaticView(cx: BASE.x, cy: BASE.y, z: 1, W: W, H: H, K: K, pad: pad, scale: Double(backing), excluded: excludedKey)
        if let o = overview, o.img.view == v { return }
        renderingOverview = true
        startRender(v) { [weak self] img in
            guard let self else { return }
            self.renderingOverview = false
            guard let img, img.view.W == self.W, img.view.H == self.H, img.view.scale == Double(self.backing) else { return }
            self.overview = self.install(img, replacing: self.overview)
        }
    }

    private func requestDetail() {
        guard W > 0, !renderingDetail, cam.tz > 1.01 else { return }
        let target = [cam.tx, cam.ty, cam.tz]
        if target != detailTarget { detailTarget = target; detailTargetAt = nowMs() }
        guard nowMs() - detailTargetAt > 400 else { return }   // a burst of lines renders once, when the camera target settles
        let v = StaticView(cx: cam.tx, cy: cam.ty, z: cam.tz, W: W, H: H, K: K, pad: pad, scale: Double(backing), excluded: excludedKey)
        if let d = detail, d.img.view == v { return }
        renderingDetail = true
        startRender(v) { [weak self] img in
            guard let self else { return }
            self.renderingDetail = false
            guard let img, img.view.W == self.W, img.view.H == self.H, img.view.scale == Double(self.backing) else { return }
            self.detail = self.install(img, replacing: self.detail)
        }
    }

    private func startRender(_ v: StaticView, _ done: @escaping (StaticImage?) -> Void) {
        let city = self.city, sp = sprites.images
        renderQueue.async {
            let img = StaticRenderer.render(v, city: city, sprites: sp)
            DispatchQueue.main.async {
                if let img { self.lastStaticMs = img.ms }
                done(img)
            }
        }
    }

    private func install(_ img: StaticImage, replacing old: (img: StaticImage, layer: CALayer, dash: CAShapeLayer)?)
        -> (img: StaticImage, layer: CALayer, dash: CAShapeLayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let l = mk(CALayer())
        l.anchorPoint = .zero
        l.bounds = CGRect(x: 0, y: 0, width: img.view.W + 2 * img.view.pad, height: img.view.H + 2 * img.view.pad)
        l.contents = img.image
        l.contentsGravity = .resize
        l.magnificationFilter = .linear; l.minificationFilter = .trilinear
        let dash = mk(CAShapeLayer(), l)
        dash.frame = l.bounds
        dash.path = img.dashes
        dash.fillColor = nil
        dash.strokeColor = RGB(255, 214, 150).cg(0.5)
        dash.lineWidth = CGFloat(max(1, img.unit * 0.2))
        dash.lineCap = .round
        dash.lineDashPattern = [NSNumber(value: img.unit * 0.6), NSNumber(value: img.unit * 1.8)]
        dash.contentsScale = backing
        if img.view.z > 1, let o = overview?.layer { staticGroup.insertSublayer(l, above: o) }
        else { staticGroup.insertSublayer(l, at: 0) }
        old?.layer.removeFromSuperlayer()
        CATransaction.commit()
        return (img, l, dash)
    }

    /// Places a static image so it tracks the live camera; returns whether it covers the whole screen.
    @discardableResult
    private func track(_ t: (img: StaticImage, layer: CALayer, dash: CAShapeLayer), _ now: Double) -> Bool {
        let v = t.img.view
        var s = cam.z / v.z
        if abs(s - 1) < 1e-6 { s = 1 }
        let u = K * cam.z
        var ox = W / 2 + (v.cx - cam.x) * u + (-v.pad - W / 2) * s
        var oy = H / 2 + 30 + (v.cy - cam.y) * u + (-v.pad - (H / 2 + 30)) * s
        let bs = Double(backing)
        if s == 1 { ox = (ox * bs).rounded() / bs; oy = (oy * bs).rounded() / bs }   // 1:1 on the pixel grid: crisp
        t.layer.position = CGPoint(x: ox, y: oy)
        t.layer.transform = s == 1 ? CATransform3DIdentity : CATransform3DMakeScale(CGFloat(s), CGFloat(s), 1)
        let period = t.img.unit * 2.4
        t.dash.lineDashPhase = CGFloat((-(now / 40) / s).truncatingRemainder(dividingBy: period))
        let w = (v.W + 2 * v.pad) * s, h = (v.H + 2 * v.pad) * s
        return ox <= 0 && oy <= 0 && ox + w >= W && oy + h >= H
    }

    // ---- frame ------------------------------------------------------------------------------------------------------------
    private func step() {
        guard running, W > 0 else { return }   // a stopped instance the host keeps ticking stays idle
        let now = nowMs()
        let dt = min(0.05, (now - last) / 1000); last = now
        let decay = pow(0.965, dt * 60)   // the page decays pulses per frame at 60 fps
        feed.tick(now)
        moveCamera(now, dt)
        for c in cabs.values { fly(c, now, dt) }
        for c in npcs { drive(c, dt) }

        // towers on the map now, and the lots their static layer must leave empty
        let shown = towerOrder.compactMap { towers[$0] }.filter { $0.lot != nil }
        let ex = shown.compactMap { $0.lot?.idx }.sorted()
        if ex != excludedKey {
            if excludedChangedAt == 0 { excludedChangedAt = now }
            if now - excludedChangedAt > 400 { excludedKey = ex; excludedChangedAt = 0 }   // coalesce a burst of placements
        } else { excludedChangedAt = 0 }
        requestOverview()
        requestDetail()

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let u = unit
        // backdrop and sky
        if let sky = sprites.sky {
            let sw = max(W, H * 1.6) * 1.2, sh = sw * Double(sky.height) / Double(sky.width)
            skyLayer.frame = CGRect(x: (W - sw) / 2 - (cam.x - BASE.x) * K * 0.15, y: -sh * 0.12 - (cam.y - BASE.y) * K * 0.1, width: sw, height: sh)
        }
        // static city: the overview below, the latest detail view over it while the camera is in close
        var covered = false
        if let o = overview { track(o, now) }
        if let d = detail {
            let show = cam.tz > 1.01 || cam.z > 1.12
            d.layer.isHidden = !show
            if show { covered = track(d, now) }
        }
        overview?.layer.isHidden = covered

        drawNpcs(now, u)
        drawTowers(now, u, shown, decay)
        drawNames(u, shown)
        for (i, l) in city.holos.enumerated() where i < holoLayers.count {
            let h = holoLayers[i], p = P(l.x, l.y, 9 + sin(now / 1800 + Double(l.h)) * 0.8), w = u * 7
            h.bounds = CGRect(x: 0, y: 0, width: w, height: w); h.position = p
            h.transform = l.h % 2 == 1 ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            h.opacity = Float(0.35 + 0.2 * sin(now / 900 + Double(l.h)))
        }
        drawCabs(now, u, decay)
        for f in flyers {
            let t = now / 1000 * f.v + f.p, x = CX + cos(t) * f.rx, y = CY + sin(t * 1.3) * f.ry
            let p = P(x, y, f.alt), w = u * 2.4
            let dx = -sin(t) * f.rx, dy = cos(t * 1.3) * 1.3 * f.ry, vx = dx - dy
            f.layer?.bounds = CGRect(x: 0, y: 0, width: w, height: w); f.layer?.position = p
            f.layer?.transform = vx < 0 ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        }
        drawBeams(now)
        drawRipples(now, u)
        drawLabels(now)
        let rp = CGMutablePath()
        for d in rain {
            let x = (d.0 * W + now * 0.04 * d.2).truncatingRemainder(dividingBy: W), y = (d.1 * H + now * 0.5 * d.2).truncatingRemainder(dividingBy: H)
            rp.move(to: CGPoint(x: x, y: y)); rp.addLine(to: CGPoint(x: x - 3, y: y + 14 * d.2))
        }
        rainLayer.path = rp
        CATransaction.commit()

        guard diagnostics else { return }
        fpsFrames += 1
        if now - fpsSince >= 1000 { measuredFPS = Double(fpsFrames) * 1000 / (now - fpsSince); fpsFrames = 0; fpsSince = now }
        if !frameWritten && now - started > 20000 { frameWritten = true; writeFrame() }
    }

    private func drive(_ car: Npc, _ dt: Double) {
        let len = jsHypot(car.b.x - car.a.x, car.b.y - car.a.y), seg = len == 0 ? 1 : len
        car.t += car.speed * (car.a.hw && car.b.hw ? 2 : 1) * dt / seg
        var hops = 0
        while car.t >= 1 && hops < 64 {   // a long frame on short segments: bounded
            hops += 1
            car.t -= 1
            let nxt = nextHop(car)
            car.a = car.b; car.b = nxt
            if car.a === car.b { car.t = 0; break }
        }
        car.x = car.a.x + (car.b.x - car.a.x) * car.t; car.y = car.a.y + (car.b.y - car.a.y) * car.t
        if car.a !== car.b { car.dir = (car.b.x - car.a.x, car.b.y - car.a.y) }
    }

    private func nextHop(_ car: Npc) -> GNode {
        let here = car.b
        var opts = here.adj.filter { $0.to != car.a.id }
        if car.hwLover { let hw = opts.filter { $0.hw }; if !hw.isEmpty && Double.random(in: 0..<1) < 0.85 { opts = hw } }
        if opts.isEmpty { opts = here.adj }
        return opts.isEmpty ? here : city.nodes[opts[Int.random(in: 0..<opts.count)].to]
    }

    private func drawNpcs(_ now: Double, _ u: Double) {
        let trails = CGMutablePath()
        let L = u * 0.7, Wd = L * 0.45
        for car in npcs {
            car.trail.append((car.x, car.y, now))
            while let f = car.trail.first, now - f.t > 200 { car.trail.removeFirst() }   // 12 frames at 60 fps
            let p = P(car.x, car.y)
            let off = p.x < -40 || p.x > W + 40 || p.y < -40 || p.y > H + 40
            car.layer.isHidden = off
            if off { continue }
            for (k, pt) in car.trail.enumerated() {
                let q = P(pt.x, pt.y)
                if k == 0 { trails.move(to: q) } else { trails.addLine(to: q) }
            }
            let a = (car.dir.0 - car.dir.1), b = (car.dir.0 + car.dir.1) * 0.5, ang = atan2(b, a)
            let body = car.layer!
            body.bounds = CGRect(x: 0, y: 0, width: L, height: Wd)
            body.position = p
            body.transform = CATransform3DMakeRotation(CGFloat(ang), 0, 0, 1)
            for s in body.sublayers ?? [] {
                switch s.name {
                case "shell": s.frame = body.bounds; s.cornerRadius = CGFloat(Wd * 0.4)
                case "head": s.frame = CGRect(x: L, y: -Wd / 2, width: L * 1.8, height: Wd * 2)
                default: s.frame = CGRect(x: 0, y: 0, width: max(1, L * 0.1), height: Wd)
                }
            }
        }
        npcTrails.lineWidth = CGFloat(max(1, u * 0.2))
        npcTrails.path = trails
    }

    private func drawTowers(_ now: Double, _ u: Double, _ shown: [Tower], _ decay: Double) {
        var live = Set<String>()
        for tw in shown + [owner] {
            live.insert(tw.key)
            let isOwner = tw.kind == .owner
            guard let lot = isOwner ? city.owner : tw.lot else { continue }
            let L = tw.layers ?? {
                let l = TowerLayers(towerGroup)
                l.glow.contentsScale = backing; l.beacon.contentsScale = backing
                setGlow(l.glow, tw.color)
                setGlow(l.beacon, isOwner ? Pal.gold : Pal.magenta)
                l.sprite.contents = isOwner ? sprites.images["owner-tower"] : (sprites.images[TOWERS[0]] ?? sprites.images["hub-tower"])
                if !isOwner { l.sign = text(signGroup, scale: backing, color: RGB(0xffd6f6).cg(0.92)) ; l.sign?.shadowColor = Pal.magenta.cg(); l.sign?.shadowOpacity = 1; l.sign?.shadowOffset = .zero }
                tw.layers = l
                return l
            }()
            let p = P(lot.x, lot.y), stepW = isOwner ? 6.5 : TOWER_STEP
            let w = stepW * 2 * u * (isOwner ? 1.35 : 1.05), h = w * 4 / 3, base = isOwner ? 0.9 : 0.86
            L.group.zPosition = CGFloat(lot.x + lot.y)
            placeGlow(L.glow, p, u * stepW * (0.9 + tw.pulse * 0.8), 0.25 + tw.pulse * 0.5)
            L.sprite.frame = CGRect(x: Double(p.x) - w / 2, y: Double(p.y) - h * base, width: w, height: h)
            let top = P(lot.x, lot.y, towerLift(tw)).y, beat = 0.5 + 0.5 * sin(now / 700 + Double(jsHash(tw.key) % 10))
            placeGlow(L.beacon, CGPoint(x: p.x, y: top), u * (1.6 + beat * 0.6 + tw.pulse * 2), 0.55 + tw.pulse * 0.4)
            if let sign = L.sign {   // the stage's name as a neon sign over the street
                let dim = tw.open ? 1.0 : 0.45
                sign.set(tw.label, CGFloat(max(10, u * 1.15)))
                sign.foregroundColor = (tw.open ? RGB(0xffd6f6) : Pal.dim).cg(0.92 * dim)
                sign.shadowRadius = CGFloat((8 + tw.pulse * 14) / 2)
                sign.place(p.x, baseline: p.y + CGFloat(u * 2.4), align: 0.5)
            }
            tw.pulse *= decay
        }
        for (k, tw) in towers where !live.contains(k) { tw.layers?.remove(); tw.layers = nil }
        // towers dropped from the model since the last frame
        for l in towerGroup.sublayers ?? [] where !(shown + [owner]).contains(where: { $0.layers?.group === l }) {
            l.removeFromSuperlayer()
        }
        for l in signGroup.sublayers ?? [] where !shown.contains(where: { $0.layers?.sign === l }) { l.removeFromSuperlayer() }
    }

    private func drawNames(_ u: Double, _ shown: [Tower]) {
        let byD = repos.byDistrict
        for n in names {
            let repo = byD[n.d.id], p = P(n.d.x, n.d.y)
            n.name.set(n.d.name, CGFloat(max(11, u * 2.1)))
            n.name.foregroundColor = repo != nil ? RGB(79, 227, 255).cg(0.6) : RGB(138, 150, 166).cg(0.35)
            n.name.place(p.x, baseline: p.y + CGFloat(u * 9), align: 0.5)
            n.repo.isHidden = repo == nil
            if let repo {
                n.repo.set(repo, CGFloat(max(10, u * 1.3)))
                n.repo.place(p.x, baseline: p.y + CGFloat(u * 11.2), align: 0.5)
            }
        }
        let w = shown.contains { $0.district == "wastes" }
        wastes.0.isHidden = !w; wastes.1.isHidden = !w
        if w {
            let p = P(CX + 34, CY + 38)
            wastes.0.set("WASTES", CGFloat(max(11, u * 2))); wastes.0.place(p.x, baseline: p.y, align: 0.5)
            wastes.1.set(Strings.current.noRepo, CGFloat(max(10, u * 1.3))); wastes.1.place(p.x, baseline: p.y + CGFloat(u * 2.2), align: 0.5)
        }
    }

    private func drawCabs(_ now: Double, _ u: Double, _ decay: Double) {
        for c in cabs.values {
            let L = c.layers ?? { let l = CabLayers(cabGroup, scale: backing); l.glow.contentsScale = backing; c.layers = l; return l }()
            if L.tint != c.color.key { L.tint = c.color.key; L.sprite.contents = sprites.flyer(c.color); setGlow(L.glow, c.color)
                L.trail.strokeColor = c.color.cg(0.28) }
            let g = P(c.x, c.y), p = P(c.x, c.y, c.z), w = u * 3.4
            L.group.zPosition = CGFloat(c.x + c.y)
            L.shadow.bounds = CGRect(x: 0, y: 0, width: w * 0.7, height: w * 0.7)
            L.shadow.cornerRadius = CGFloat(w * 0.35)
            L.shadow.position = g
            L.shadow.transform = CATransform3DMakeScale(1, CGFloat(0.16 / 0.35), 1)
            c.trail.append((c.x, c.y, c.z, now))
            while let f = c.trail.first, now - f.t > 300 { c.trail.removeFirst() }   // 18 frames at 60 fps
            let tp = CGMutablePath()
            for (k, t) in c.trail.enumerated() {
                let q = P(t.x, t.y, t.z), q2 = CGPoint(x: q.x, y: q.y + CGFloat(w * 0.15))
                if k == 0 { tp.move(to: q2) } else { tp.addLine(to: q2) }
            }
            L.trail.path = tp
            L.trail.lineWidth = CGFloat(max(1, u * 0.3))
            let wob = c.working ? 0.15 * (1 + sin(now / 300)) : 0
            placeGlow(L.glow, CGPoint(x: p.x, y: p.y + CGFloat(w * 0.2)), w * (0.55 + c.pulse * 0.6 + wob), 0.35 + c.pulse * 0.5)
            let vx = (c.x - c.px) - (c.y - c.py)
            L.sprite.bounds = CGRect(x: 0, y: 0, width: w, height: w)
            L.sprite.position = p
            L.sprite.transform = vx < 0 ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            if c.pulse > 0.1 {
                L.label.isHidden = false
                L.label.set(c.label, CGFloat(max(10, u * 0.95)))
                L.label.opacity = Float(c.pulse)
                L.label.place(p.x, baseline: p.y - CGFloat(w * 0.45), align: 0.5)
            } else { L.label.isHidden = true }
            c.pulse *= decay
        }
        for l in cabGroup.sublayers ?? [] where !cabs.values.contains(where: { $0.layers?.group === l }) { l.removeFromSuperlayer() }
    }

    private func bez(_ a: CGPoint, _ b: CGPoint, _ t: Double, _ lift: Double) -> CGPoint {
        let mx = Double(a.x + b.x) / 2, my = Double(min(a.y, b.y)) - lift, u = 1 - t
        return CGPoint(x: u * u * Double(a.x) + 2 * u * t * mx + t * t * Double(b.x), y: u * u * Double(a.y) + 2 * u * t * my + t * t * Double(b.y))
    }

    private func drawBeams(_ now: Double) {
        var i = beams.count - 1
        while i >= 0 {
            var bm = beams[i]
            let t = (now - bm.t0) / bm.dur
            if t >= 1.25 { bm.line.removeFromSuperlayer(); bm.head.removeFromSuperlayer(); beams.remove(at: i); i -= 1; continue }
            let A = anchor(bm.a), B = anchor(bm.b)
            let lift = min(220, Double(hypot(B.x - A.x, B.y - A.y)) * 0.35 + 30)
            let head = min(1, t), tail = max(0, t - 0.45)
            let path = CGMutablePath()
            for k in 0...24 {
                let q = bez(A, B, tail + (head - tail) * Double(k) / 24, lift)
                if k == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            bm.line.path = path
            bm.line.opacity = Float(max(0, 1 - max(0, t - 1) * 4))
            placeGlow(bm.head, bez(A, B, head, lift), 14, 0.8)
            if t >= 1 && !bm.hit {
                bm.hit = true; bm.b.pulse = 1
                let fixed = B
                addRipple({ fixed }, now, bm.color)
                beams[i] = bm
            }
            i -= 1
        }
    }

    private func drawRipples(_ now: Double, _ u: Double) {
        var i = ripples.count - 1
        while i >= 0 {
            let r = ripples[i], t = (now - r.t0) / 1200
            if t >= 1 { r.layer.removeFromSuperlayer(); ripples.remove(at: i); i -= 1; continue }
            let p = r.at(), rad = 6 + t * u * 4
            r.layer.path = CGPath(ellipseIn: CGRect(x: Double(p.x) - rad, y: Double(p.y) - rad / 2, width: 2 * rad, height: rad), transform: nil)
            r.layer.opacity = Float(1 - t)
            i -= 1
        }
    }

    private func drawLabels(_ now: Double) {
        var i = labels.count - 1
        while i >= 0 {
            let l = labels[i], t = (now - l.t0) / 5600
            if t >= 1 { l.group.removeFromSuperlayer(); labels.remove(at: i); i -= 1; continue }
            let a = t < 0.08 ? t / 0.08 : 1 - max(0, (t - 0.6) / 0.4)
            let p = anchor(l.who)
            let x = min(Double(p.x) + 18, W - 380), y = Double(p.y) - 10 - t * 12
            let w = Double(l.txt.measured.width) + 18
            l.bg.frame = CGRect(x: x, y: y - 14, width: w, height: 21)
            l.bar.frame = CGRect(x: x, y: y - 14, width: 2, height: 21)
            l.txt.place(CGFloat(x + 10), baseline: CGFloat(y + 1), align: 0)
            l.group.opacity = Float(a)
            i -= 1
        }
    }

    // ---- diagnostics: one composited frame as PNG in $TMPDIR, 20 s after start --------------------------------------------
    private func writeFrame() {
        let w = Int(W), h = Int(H)
        guard w > 0, h > 0, let root = layer,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        root.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(instance == 1 ? "delamain-frame.png" : "delamain-frame-\(instance).png")
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dst = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return }
        let enc = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        feed.ping("/state?saver=native&frame=written&path=\(enc)&fps=\(String(format: "%.1f", measuredFPS))&view=\(instance)&size=\(w)x\(h)")
    }
}
