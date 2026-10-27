// The hub-viz server as the saver sees it: /state polled every 5 s (the poll carries the saver's opt-in diagnostics),
// /events streamed as SSE with reconnects, and /history for an opt-in replay of a quiet stretch.
// Everything is delivered on the main thread.
import Foundation

struct HubInfo: Decodable { var tag: String?; var kind: String?; var host: String?; var title: String? }
struct Worker: Decodable {
    var role: String; var tag: String?; var engine: String?; var model: String?
    var working: Bool?; var title: String?
}
struct StageView: Decodable {
    var name: String; var repo: String?; var open: Bool?; var goal: String?; var hub: HubInfo?; var workers: [Worker]?
}
struct State: Decodable { var machine: String; var at: String?; var stages: [StageView]? }
struct Event: Decodable {
    var stage: String; var repo: String?; var tag: String?; var text: String; var at: String
    var from: [String]; var engine: String?; var to: [[String]]?
}
struct History: Decodable { var machine: String?; var lines: [Event]? }

/// Milliseconds on the same clock as the renderer (CACurrentMediaTime).
func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

final class Feed: NSObject, URLSessionDataDelegate {
    static let SPEED = 120.0, REPLAY_HOURS = 24.0
    let base: URL
    /// seconds without a live line before the replay starts; nil = never (the default: realtime only)
    let quietMs: Double?
    var onState: ((State) -> Void)?
    var onLine: ((Event, Bool) -> Void)?
    var onOnline: ((Bool, String?) -> Void)?
    var onReplay: ((Event?) -> Void)?   // the replayed line now shown, or nil when the replay stops
    var diagnostics: (() -> String)?   // query of the /state poll; nil = a plain poll

    private var requests: URLSession!
    private var stream: URLSession?
    private var streamTask: URLSessionDataTask?
    private var buffer = Data()
    private var backoff = 1.0
    private var running = false
    private var nextPoll = 0.0
    private(set) var lastLive = nowMs()
    private var replay: (all: [Event], times: [Double], i: Int, next: Double)?
    private var asking = false, retryReplayAt = 0.0
    private(set) var stateSeen = false

    init(base: URL, quietSeconds: Double?) {
        self.base = base
        self.quietMs = quietSeconds.map { $0 * 1000 }
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        requests = URLSession(configuration: cfg, delegate: nil, delegateQueue: .main)
    }

    var replaying: Bool { replay != nil }

    func start() {
        guard !running else { return }
        running = true
        lastLive = nowMs()
        nextPoll = 0
        connect()
    }

    func stop() {
        running = false
        streamTask?.cancel(); streamTask = nil
        stream?.invalidateAndCancel(); stream = nil
    }

    private func url(_ pathAndQuery: String) -> URL { URL(string: base.absoluteString.trimmingCharacters(in: ["/"]) + pathAndQuery)! }

    /// Called from the frame clock: the /state poll and the replay ride on it, so nothing depends on host timers.
    func tick(_ now: Double) {
        guard running else { return }
        if now >= nextPoll {
            nextPoll = now + 5000
            poll()
        }
        if let quietMs, replay == nil, !asking, now >= retryReplayAt, now - lastLive > quietMs { startReplay(now) }
        stepReplay(now)
    }

    private func poll() {
        var q = "/state"
        if let d = diagnostics?() { q += "?" + d }
        requests.dataTask(with: url(q)) { [weak self] data, _, err in
            guard let self, self.running else { return }
            if let data, let st = try? JSONDecoder().decode(State.self, from: data) {
                self.stateSeen = true
                self.onState?(st)
            } else if !self.stateSeen {
                self.onOnline?(false, err?.localizedDescription ?? Strings.current.noState)
            }
        }.resume()
    }

    /// A fire-and-forget GET (diagnostics).
    func ping(_ pathAndQuery: String) { requests.dataTask(with: url(pathAndQuery)) { _, _, _ in }.resume() }

    // ---- SSE ---------------------------------------------------------------------------------------------------------
    private func connect() {
        guard running else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120   // the server pings every 15 s
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        stream = s
        buffer.removeAll()
        var req = URLRequest(url: url("/events"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let t = s.dataTask(with: req)
        streamTask = t
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === stream else { return }
        backoff = 1
        buffer.append(data)
        // frames end with a blank line; tolerate \r\n
        while true {
            var range = buffer.range(of: Data([10, 10]))
            if range == nil { range = buffer.range(of: Data([13, 10, 13, 10])) }
            guard let r = range else { break }
            let frame = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            handleFrame(String(decoding: frame, as: UTF8.self))
        }
    }

    private func handleFrame(_ text: String) {
        var event = "message", data: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.hasPrefix(":") || line.isEmpty { continue }
            if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("data:") {
                var d = line.dropFirst(5)
                if d.hasPrefix(" ") { d = d.dropFirst() }
                data.append(String(d))
            }
        }
        guard !data.isEmpty, let json = data.joined(separator: "\n").data(using: .utf8) else { return }
        switch event {
        case "state":
            if let st = try? JSONDecoder().decode(State.self, from: json) {
                stateSeen = true
                onOnline?(true, nil)
                onState?(st)
            }
        case "line":
            if let ev = try? JSONDecoder().decode(Event.self, from: json) {
                lastLive = nowMs()
                stopReplay()
                onLine?(ev, false)
            }
        default: break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === stream else { return }
        session.finishTasksAndInvalidate()
        stream = nil; streamTask = nil
        guard running else { return }
        onOnline?(false, error?.localizedDescription ?? Strings.current.streamClosed)
        let wait = backoff
        backoff = min(30, backoff * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
    }

    // ---- replay (opt-in) ----------------------------------------------------------------------------------------------
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func date(_ at: String) -> Date? {
        if let d = iso.date(from: at) { return d }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: at)
    }

    private func startReplay(_ now: Double) {
        asking = true
        let hours = Int(Feed.REPLAY_HOURS)
        requests.dataTask(with: url("/history?hours=\(hours)")) { [weak self] data, _, _ in
            guard let self else { return }
            self.asking = false
            guard self.running, self.replay == nil else { return }
            let lines = (data.flatMap { try? JSONDecoder().decode(History.self, from: $0) }?.lines) ?? []
            if lines.isEmpty { self.retryReplayAt = nowMs() + 30000; return }
            let all = lines.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
                .map { $0.element }
            let times = all.map { (Feed.date($0.at)?.timeIntervalSince1970 ?? 0) * 1000 }
            self.replay = (all, times, 0, nowMs() + 400)
        }.resume()
    }

    private func stopReplay() {
        guard replay != nil else { return }
        replay = nil
        onReplay?(nil)
    }

    private func stepReplay(_ now: Double) {
        guard var r = replay, now >= r.next else { return }
        let ev = r.all[r.i]
        onLine?(ev, true)
        onReplay?(ev)
        let prevT = r.times[r.i]
        r.i += 1
        if r.i >= r.all.count { r.i = 0; r.next = now + 6000 }
        else {
            let gap = (r.times[r.i] - prevT) / Feed.SPEED
            r.next = now + max(450, min(gap, 5000))
        }
        if replay != nil { replay = r }
    }
}
