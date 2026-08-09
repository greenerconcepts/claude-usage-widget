import AppKit
import CoreServices
import Security
import ServiceManagement

// MARK: - Data types

struct Gauge {
    var pct: Int?          // 0-100, nil = unknown
    var reset: Date?
    var resetIsWeekly = false
}

struct UsageState {
    var session = Gauge()
    var week = Gauge(resetIsWeekly: true)
    var fable = Gauge(resetIsWeekly: true)
}

// Claude-family palette, one identity color per gauge.
enum Palette {
    static let session = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.30, alpha: 1) // terracotta
    static let week    = NSColor(calibratedRed: 0.74, green: 0.56, blue: 0.25, alpha: 1) // ochre
    static let fable   = NSColor(calibratedRed: 0.45, green: 0.58, blue: 0.53, alpha: 1) // sage

    static func tinted(_ base: NSColor, pct: Int?) -> NSColor {
        guard let p = pct else { return .tertiaryLabelColor }
        if p >= 90 { return .systemRed }
        if p >= 70 { return .systemOrange }
        return base
    }
}

// MARK: - Local data sources

/// Reads the percentages the Claude desktop app itself caches (~every 15 min while open).
final class PlanUsageReader {
    static let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

    struct Result { var sessionPct: Int?; var weekPct: Int?; var weeklyReset: Date? }

    func read() -> Result {
        var r = Result()
        guard let data = FileManager.default.contents(atPath: PlanUsageReader.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]], !samples.isEmpty else { return r }

        if let last = samples.last, let u = last["u"] as? [String: Any] {
            r.sessionPct = u["fh"] as? Int
            r.weekPct = u["sd"] as? Int
        }

        // Weekly reset: find the most recent big drop in the 7-day gauge, snap to
        // Anthropic's :59 convention, then roll forward in 7-day steps.
        var prev: Int?
        var lastDrop: Date?
        for s in samples {
            guard let u = s["u"] as? [String: Any], let sd = u["sd"] as? Int,
                  let t = s["t"] as? Double else { continue }
            if let p = prev, sd < p - 4 {
                lastDrop = Date(timeIntervalSince1970: t / 1000)
            }
            prev = sd
        }
        if let drop = lastDrop {
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: drop)
            comps.minute = 59
            comps.second = 0
            if var reset = cal.date(from: comps) {
                reset = reset.addingTimeInterval(-3600) // drop sample trails the reset; :59 of the previous hour
                while reset <= Date() { reset = reset.addingTimeInterval(7 * 86400) }
                r.weeklyReset = reset
            }
        }
        return r
    }
}

/// Tails Claude Code's JSONL logs just to find when the current 5h session window opened.
final class SessionWindowReader {
    private let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    private var offsets: [String: UInt64] = [:]
    private var stamps: [String: [Date]] = [:]

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func refresh() {
        guard let en = FileManager.default.enumerator(atPath: root) else { return }
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(rel)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? UInt64 else { continue }
            if size < (offsets[path] ?? 0) { offsets[path] = 0; stamps[path] = [] }
            if size > (offsets[path] ?? 0) { ingest(path) }
        }
    }

    private func ingest(_ path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let start = offsets[path] ?? 0
        fh.seek(toFileOffset: start)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        var consumable = data
        var consumed = UInt64(data.count)
        if data.last != UInt8(ascii: "\n") {
            guard let nl = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            consumable = data.subdata(in: 0..<(nl + 1))
            consumed = UInt64(nl + 1)
        }
        offsets[path] = start + consumed
        var dates = stamps[path] ?? []
        consumable.split(separator: UInt8(ascii: "\n")).forEach { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  msg["usage"] != nil,
                  let ts = obj["timestamp"] as? String,
                  let d = SessionWindowReader.isoFrac.date(from: ts) ?? SessionWindowReader.iso.date(from: ts)
            else { return }
            dates.append(d)
        }
        stamps[path] = dates
    }

    /// End of the current 5h window (windows open at the top of the hour of the first message).
    func currentWindowEnd(now: Date = Date()) -> Date? {
        let all = stamps.values.flatMap { $0 }.sorted()
        guard !all.isEmpty else { return nil }
        let cal = Calendar.current
        var end: Date?
        for d in all {
            if let e = end, d < e { continue }
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: d)
            comps.minute = 0; comps.second = 0
            end = (cal.date(from: comps) ?? d).addingTimeInterval(5 * 3600)
        }
        if let e = end, now < e { return e }
        return nil
    }
}

// MARK: - Anthropic usage API (exact percentages incl. Fable; needs a CLI sign-in once)

final class UsageAPI {
    private var tokenMissing = false // avoid re-prompting keychain every poll
    func retryToken() { tokenMissing = false }

    struct ApiGauges { var session: Gauge?; var week: Gauge?; var model: Gauge?; var modelName: String? }

    private struct Creds {
        var access: String
        var refresh: String?
        var expiresAt: Date?
        var fullItem: [String: Any] // whole keychain JSON, preserved on writes
    }

    private static let service = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code's public OAuth client

    // MARK: keychain

    private func loadCreds() -> Creds? {
        if tokenMissing { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: UsageAPI.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            tokenMissing = true
            return nil
        }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        return Creds(access: token,
                     refresh: oauth["refreshToken"] as? String,
                     expiresAt: expires,
                     fullItem: obj)
    }

    private func persist(access: String, refresh: String?, expiresIn: Double?, base: Creds) {
        var full = base.fullItem
        var oauth = (full["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = access
        if let r = refresh { oauth["refreshToken"] = r }
        if let e = expiresIn { oauth["expiresAt"] = (Date().timeIntervalSince1970 + e) * 1000 }
        full["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: full) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: UsageAPI.service,
        ]
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    // MARK: token refresh

    private func refreshAccessToken(_ creds: Creds, completion: @escaping (String?) -> Void) {
        guard let refresh = creds.refresh,
              let url = URL(string: "https://console.anthropic.com/v1/oauth/token") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": UsageAPI.clientID,
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String else {
                completion(nil); return
            }
            // Keep the CLI's keychain entry in sync so both stay signed in.
            self?.persist(access: access,
                          refresh: obj["refresh_token"] as? String,
                          expiresIn: obj["expires_in"] as? Double,
                          base: creds)
            completion(access)
        }.resume()
    }

    // MARK: usage fetch

    private static func parseISO(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        // Trim micro/nano-second fractions down to milliseconds and retry.
        if let range = s.range(of: #"\.(\d{3})\d+"#, options: .regularExpression) {
            let trimmed = s.replacingCharacters(in: range, with: String(s[range].prefix(4)))
            return frac.date(from: trimmed) ?? plain.date(from: trimmed)
        }
        return nil
    }

    private static func parse(_ obj: [String: Any]) -> ApiGauges? {
        var out = ApiGauges()
        func gauge(pct: Any?, reset: Any?, weekly: Bool) -> Gauge? {
            var g = Gauge(resetIsWeekly: weekly)
            if let p = pct as? Double { g.pct = Int(p.rounded()) }
            else if let p = pct as? Int { g.pct = p }
            if let rs = reset as? String { g.reset = parseISO(rs) }
            return g.pct != nil ? g : nil
        }
        // Preferred: the `limits` array (this is what the app's usage screen shows).
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits {
                let kind = (l["kind"] as? String) ?? ""
                switch kind {
                case "session":
                    out.session = gauge(pct: l["percent"], reset: l["resets_at"], weekly: false)
                case "weekly_all":
                    out.week = gauge(pct: l["percent"], reset: l["resets_at"], weekly: true)
                case "weekly_scoped":
                    out.model = gauge(pct: l["percent"], reset: l["resets_at"], weekly: true)
                    if let scope = l["scope"] as? [String: Any],
                       let model = scope["model"] as? [String: Any],
                       let name = model["display_name"] as? String {
                        out.modelName = name
                    }
                default: break
                }
            }
        }
        // Fallback: legacy top-level objects.
        if out.session == nil, let d = obj["five_hour"] as? [String: Any] {
            out.session = gauge(pct: d["utilization"], reset: d["resets_at"], weekly: false)
        }
        if out.week == nil, let d = obj["seven_day"] as? [String: Any] {
            out.week = gauge(pct: d["utilization"], reset: d["resets_at"], weekly: true)
        }
        return out.session != nil || out.week != nil || out.model != nil ? out : nil
    }

    func fetch(completion: @escaping (ApiGauges?) -> Void) {
        guard let creds = loadCreds() else { completion(nil); return }
        let stale = creds.expiresAt.map { $0.timeIntervalSinceNow < 120 } ?? false
        if stale {
            refreshAccessToken(creds) { [weak self] token in
                guard let token = token else { completion(nil); return }
                self?.request(token: token, retryCreds: nil, completion: completion)
            }
        } else {
            request(token: creds.access, retryCreds: creds, completion: completion)
        }
    }

    private func request(token: String, retryCreds: Creds?, completion: @escaping (ApiGauges?) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, let creds = retryCreds {
                // Token revoked/expired early — refresh once and retry.
                self?.refreshAccessToken(creds) { fresh in
                    guard let fresh = fresh else { completion(nil); return }
                    self?.request(token: fresh, retryCreds: nil, completion: completion)
                }
                return
            }
            guard status == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil); return
            }
            completion(UsageAPI.parse(obj))
        }.resume()
    }
}

// MARK: - FSEvents watcher

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "usage.fsevents")
    private let onChange: () -> Void

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

// MARK: - UI pieces

final class BarView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    var base: NSColor = Palette.session
    var pct: Int? {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.cornerRadius = 2.5
        fill.cornerRadius = 2.5
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 5) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        let frac = CGFloat(min(max(pct ?? 0, 0), 100)) / 100
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * frac, height: bounds.height)
        fill.backgroundColor = Palette.tinted(base, pct: pct).cgColor
        CATransaction.commit()
    }
}

final class GaugeRow {
    let name: NSTextField
    let value = NSTextField(labelWithString: "—")
    let bar = BarView(frame: .zero)
    let caption = NSTextField(labelWithString: " ")
    let base: NSColor

    init(_ title: String, color: NSColor) {
        base = color
        name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        name.textColor = .labelColor
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        value.alignment = .right
        caption.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        caption.textColor = .tertiaryLabelColor
        bar.base = color
    }

    func views() -> [NSView] {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [name, spacer, value])
        top.orientation = .horizontal
        return [top, bar, caption]
    }

    func apply(_ g: Gauge, pending: String? = nil) {
        if let p = g.pct {
            value.stringValue = "\(p)%"
            value.textColor = Palette.tinted(base, pct: p)
            bar.pct = p
        } else {
            value.stringValue = "—"
            value.textColor = .tertiaryLabelColor
            bar.pct = nil
        }
        if let pending = pending, g.pct == nil {
            caption.stringValue = pending
            return
        }
        if let r = g.reset {
            let f = DateFormatter()
            f.dateFormat = g.resetIsWeekly || !Calendar.current.isDateInToday(r) ? "EEE h:mm a" : "h:mm a"
            caption.stringValue = "Resets \(f.string(from: r))"
        } else {
            caption.stringValue = " "
        }
    }
}

/// Full-window overlay that implements edge + corner resizing for the
/// borderless panel (macOS provides none for frameless windows, and cursor
/// rects are ignored for never-key windows — so both are done by hand here).
final class ResizeOverlay: NSView {
    weak var cardView: NSView?           // the visible card; zones hug its border
    var minW: CGFloat = 400, maxW: CGFloat = 1200
    var minH: CGFloat = 120, maxH: CGFloat = 400
    var onDone: (() -> Void)?

    private struct Zone { var dx: Int; var dy: Int } // -1/0/+1 per axis (AppKit coords: +y is up)
    private var active: Zone?
    private var start = NSPoint.zero
    private var startFrame = NSRect.zero
    private let tol: CGFloat = 10

    /// Event position in global screen coords (event-based, so synthetic events work too).
    private func globalPoint(_ event: NSEvent) -> NSPoint {
        guard let w = window else { return .zero }
        let p = event.locationInWindow
        return NSPoint(x: w.frame.origin.x + p.x, y: w.frame.origin.y + p.y)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func zone(at p: NSPoint) -> Zone? {
        guard let card = cardView?.frame else { return nil }
        let inBandX = p.x >= card.minX - tol && p.x <= card.maxX + tol
        let inBandY = p.y >= card.minY - tol && p.y <= card.maxY + tol
        guard inBandX && inBandY else { return nil }
        let dx = abs(p.x - card.minX) <= tol ? -1 : (abs(p.x - card.maxX) <= tol ? 1 : 0)
        let dy = abs(p.y - card.minY) <= tol ? -1 : (abs(p.y - card.maxY) <= tol ? 1 : 0)
        return (dx == 0 && dy == 0) ? nil : Zone(dx: dx, dy: dy)
    }

    /// Only claim clicks that land on an edge/corner band; the card's middle
    /// stays free for isMovableByWindowBackground dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return zone(at: p) != nil ? self : nil
    }

    private func diagonalCursor(nesw: Bool) -> NSCursor {
        let sel = NSSelectorFromString(nesw ? "_windowResizeNorthEastSouthWestCursor"
                                            : "_windowResizeNorthWestSouthEastCursor")
        if let cls = NSCursor.self as AnyObject as? NSObjectProtocol, cls.responds(to: sel),
           let c = cls.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return c
        }
        return .crosshair
    }

    private func cursor(for z: Zone) -> NSCursor {
        if z.dx != 0 && z.dy != 0 { return diagonalCursor(nesw: z.dx == z.dy) }
        return z.dx != 0 ? .resizeLeftRight : .resizeUpDown
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let z = zone(at: p) { cursor(for: z).set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if active == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let z = zone(at: p), let w = window else { return }
        active = z
        start = globalPoint(event)
        startFrame = w.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let z = active, let w = window else { return }
        cursor(for: z).set()
        let loc = globalPoint(event) // event position vs the window's live frame
        let dx = loc.x - start.x
        let dy = loc.y - start.y
        var f = startFrame
        if z.dx == 1 {
            f.size.width = min(max(startFrame.width + dx, minW), maxW)
        } else if z.dx == -1 {
            let nw = min(max(startFrame.width - dx, minW), maxW)
            f.origin.x = startFrame.maxX - nw
            f.size.width = nw
        }
        if z.dy == 1 {
            f.size.height = min(max(startFrame.height + dy, minH), maxH)
        } else if z.dy == -1 {
            let nh = min(max(startFrame.height - dy, minH), maxH)
            f.origin.y = startFrame.maxY - nh
            f.size.height = nh
        }
        w.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if active != nil {
            active = nil
            onDone?()
        }
    }
}

// MARK: - Floating panel (wide, low, dockable, stretchable)

final class UsagePanel: NSPanel {
    let sessionRow = GaugeRow("Current session", color: Palette.session)
    let weekRow = GaugeRow("All models · week", color: Palette.week)
    let fableRow = GaugeRow("Fable · week", color: Palette.fable)

    private let pad: CGFloat = 22 // room around the card for the drop shadow

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480 + 44, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // we draw our own, deeper shadow
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let radius: CGFloat = 16

        // Card: vibrancy masked to a rounded rect (maskImage is what actually
        // rounds the blur backdrop — layer.cornerRadius leaves it square).
        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        let maskSize = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: maskSize, height: maskSize), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        card.maskImage = mask

        // Shadow holder lifts the card off the screen.
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.masksToBounds = false
        holder.layer?.shadowColor = NSColor.black.cgColor
        holder.layer?.shadowOpacity = 0.38
        holder.layer?.shadowRadius = 14
        holder.layer?.shadowOffset = CGSize(width: 0, height: -7)

        // Hairline highlight for the 3D edge.
        let edge = NSView()
        edge.wantsLayer = true
        edge.layer?.cornerRadius = radius
        edge.layer?.borderWidth = 1
        edge.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        edge.layer?.backgroundColor = .clear

        // Two equal columns: session + week stacked on the left, Fable on the right.
        func column(_ rows: [GaugeRow], footer: NSView? = nil) -> NSStackView {
            var views: [NSView] = []
            for r in rows { views += r.views() }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            views.append(spacer)
            if let f = footer { views.append(f) }
            let col = NSStackView(views: views)
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 4
            for r in rows { col.setCustomSpacing(11, after: r.caption) }
            for v in views where v is NSStackView || v is BarView {
                v.translatesAutoresizingMaskIntoConstraints = false
                v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            }
            return col
        }

        // Small branding tucked under the Fable gauge.
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")!)
        icon.contentTintColor = Palette.session
        icon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        let brandText = NSTextField(labelWithString: "CLAUDE")
        var kerned = AttributedString("CLAUDE")
        kerned.kern = 1.5
        brandText.attributedStringValue = NSAttributedString(kerned)
        brandText.font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        brandText.textColor = .tertiaryLabelColor
        let brand = NSStackView(views: [icon, brandText])
        brand.orientation = .horizontal
        brand.spacing = 4

        let left = column([sessionRow, weekRow])
        let right = column([fableRow], footer: brand)

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 22
        columns.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        columns.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(columns)
        card.translatesAutoresizingMaskIntoConstraints = false
        edge.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(holder)
        holder.addSubview(card)
        holder.addSubview(edge)

        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            holder.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            holder.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            card.topAnchor.constraint(equalTo: holder.topAnchor),
            card.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: holder.trailingAnchor),

            edge.topAnchor.constraint(equalTo: holder.topAnchor),
            edge.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: holder.trailingAnchor),

            columns.topAnchor.constraint(equalTo: card.topAnchor),
            columns.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        contentView = root
        root.layoutSubtreeIfNeeded()
        let fit = holder.fittingSize
        let defaultSize = NSSize(width: 480 + pad * 2, height: fit.height + pad * 2)
        minSize = NSSize(width: 380 + pad * 2, height: fit.height + pad * 2)
        maxSize = NSSize(width: 1100, height: (fit.height + pad * 2) * 1.8)

        // Restore last frame, or default to docked bottom-left.
        if let saved = UserDefaults.standard.string(forKey: "panelFrame3") {
            setFrame(NSRectFromString(saved), display: true)
        } else {
            setContentSize(defaultSize)
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                setFrameOrigin(NSPoint(x: v.minX + 4, y: v.minY + 4))
            }
        }
        let save: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromRect(self.frame), forKey: "panelFrame3")
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main, using: save)
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main, using: save)

        // Edge + corner resize handling (cursor feedback and dragging).
        acceptsMouseMovedEvents = true
        let overlay = ResizeOverlay()
        overlay.cardView = holder
        overlay.minW = 380 + pad * 2
        overlay.maxW = 1200
        overlay.minH = defaultSize.height
        overlay.maxH = defaultSize.height + 220
        overlay.onDone = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromRect(self.frame), forKey: "panelFrame3")
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    override var canBecomeKey: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let planReader = PlanUsageReader()
    private let sessionReader = SessionWindowReader()
    private let api = UsageAPI()
    private var watcher: FileWatcher?
    private var statusItem: NSStatusItem!
    private var panel: UsagePanel!
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private let workQueue = DispatchQueue(label: "usage.compute", qos: .utility)
    private var lastApi: UsageAPI.ApiGauges?
    private var lastApiAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }
        buildMenu()

        panel = UsagePanel()
        if UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true {
            panel.orderFrontRegardless()
        }

        scheduleRefresh(apiToo: true)

        let planDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Claude")
        let projects = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        watcher = FileWatcher(paths: [planDir, projects]) { [weak self] in self?.scheduleRefresh(apiToo: false) }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Hit the API at most every 5 minutes; local files every minute.
            let apiDue = self.lastApiAt.map { Date().timeIntervalSince($0) > 300 } ?? true
            self.scheduleRefresh(apiToo: apiDue)
        }

        // Dev-only: replay a drag through the real event pipeline (hitTest →
        // overlay handlers) so resize behavior is testable headlessly.
        // Enable with: defaults write com.max.claudeusage enableTestHooks -bool true
        if UserDefaults.standard.bool(forKey: "enableTestHooks") {
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.max.claudeusage.testDrag"),
                object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let s = note.object as? String else { return }
                let v = s.split(separator: ",").compactMap { Double($0) }
                guard v.count == 4 else { return }
                self.performTestDrag(from: NSPoint(x: v[0], y: v[1]),
                                     to: NSPoint(x: v[2], y: v[3]))
            }
        }
    }

    /// Sends synthetic mouse events through the panel exactly as WindowServer
    /// would: down at `from`, incremental drags, up at `to` (global AppKit coords).
    private func performTestDrag(from: NSPoint, to: NSPoint) {
        func send(_ type: NSEvent.EventType, _ global: NSPoint) {
            let winPoint = NSPoint(x: global.x - panel.frame.origin.x,
                                   y: global.y - panel.frame.origin.y)
            if let e = NSEvent.mouseEvent(with: type, location: winPoint, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
        }
        send(.leftMouseDown, from)
        let steps = 8
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            send(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t,
                                            y: from.y + (to.y - from.y) * t))
        }
        send(.leftMouseUp, to)
        NSLog("ClaudeUsage: testDrag done, frame now \(NSStringFromRect(panel.frame))")
    }

    private func scheduleRefresh(apiToo: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let plan = self.planReader.read()
            self.sessionReader.refresh()
            let windowEnd = self.sessionReader.currentWindowEnd()
            DispatchQueue.main.async { self.apply(plan: plan, windowEnd: windowEnd) }
            if apiToo {
                self.lastApiAt = Date()
                self.api.fetch { gauges in
                    guard let gauges = gauges else { return }
                    DispatchQueue.main.async {
                        self.lastApi = gauges
                        self.apply(plan: plan, windowEnd: windowEnd)
                    }
                }
            }
        }
        pending = work
        workQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func apply(plan: PlanUsageReader.Result, windowEnd: Date?) {
        var state = UsageState()
        state.session.pct = plan.sessionPct
        state.session.reset = windowEnd
        state.week.pct = plan.weekPct
        state.week.reset = plan.weeklyReset
        state.fable.reset = plan.weeklyReset

        // Exact API data (incl. Fable) wins when available.
        if let apiData = lastApi {
            if let s = apiData.session { state.session.pct = s.pct; state.session.reset = s.reset ?? state.session.reset }
            if let w = apiData.week { state.week.pct = w.pct; state.week.reset = w.reset ?? state.week.reset }
            if let m = apiData.model {
                state.fable.pct = m.pct
                state.fable.reset = m.reset ?? state.fable.reset
            }
            if let name = apiData.modelName {
                panel.fableRow.name.stringValue = "\(name) · week"
            }
        }

        panel.sessionRow.apply(state.session)
        panel.weekRow.apply(state.week)
        panel.fableRow.apply(state.fable, pending: "needs one-time sign-in")

        // Menu bar: three colored percentages — session · all models · fable.
        if let button = statusItem.button {
            let title = NSMutableAttributedString(string: " ")
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            let parts: [(Int?, NSColor)] = [
                (state.session.pct, Palette.session),
                (state.week.pct, Palette.week),
                (state.fable.pct, Palette.fable),
            ]
            for (i, part) in parts.enumerated() {
                let (pct, base) = part
                let text = pct.map { "\($0)%" } ?? "–"
                let color = pct != nil ? Palette.tinted(base, pct: pct) : NSColor.tertiaryLabelColor
                title.append(NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: color, .baselineOffset: -0.5,
                ]))
                if i < parts.count - 1 {
                    title.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
            }
            button.attributedTitle = title
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show Floating Panel", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "panelVisible")
        } else {
            panel.orderFrontRegardless()
            UserDefaults.standard.set(true, forKey: "panelVisible")
        }
    }

    @objc private func refreshNow() {
        api.retryToken()
        scheduleRefresh(apiToo: true)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("ClaudeUsage: login item error \(error)")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.title = panel.isVisible ? "Hide Floating Panel" : "Show Floating Panel"
        menu.items.first(where: { $0.title == "Start at Login" })?.state =
            SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
