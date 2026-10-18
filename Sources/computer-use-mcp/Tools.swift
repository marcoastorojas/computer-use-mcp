import AppKit
import ApplicationServices
import Foundation

/// Lo que se recuerda de cada app entre llamadas: la ventana y los elementos del último screenshot.
final class Session {
    let app: NSRunningApplication
    let pid: pid_t
    let appEl: AXUIElement
    var window: WinInfo?
    var axWindow: AXUIElement?
    var nodes: [Node] = []
    var texts: [Node] = []
    var lastPoint: [CGWindowID: CGPoint] = [:]
    var prepared = false

    init(_ app: NSRunningApplication) {
        self.app = app
        pid = app.processIdentifier
        appEl = AXUIElementCreateApplication(pid)
    }

    var name: String { app.localizedName ?? "pid \(pid)" }
}

struct Target {
    var el: AXUIElement?
    var node: Node?
    var winPoint: CGPoint?
    var screenPoint: CGPoint?
    var how: String  // index | coordinate | focused | last
    var win: WinInfo
}

final class Tools {
    private var sessions: [pid_t: Session] = [:]
    private let capturer = Capturer()
    private var launched: [NSRunningApplication] = []

    // MARK: Entrada

    func prewarm() {
        if Perm.screenOK { capturer.prewarm() }
    }

    func call(_ name: String, _ args: JSON) -> ToolResult {
        let t0 = nowMs()
        var r = run(name, args)
        r.text += "  [\(Int((nowMs() - t0).rounded())) ms]"
        return r
    }

    private func run(_ name: String, _ args: JSON) -> ToolResult {
        do {
            switch name {
            case "list_apps": return listApps()
            case "open_app": return try openApp(args)
            case "hide_cursor": return hideCursor()
            case "batch": return try batch(args)
            default: break
            }
            let s = try session(args)
            switch name {
            case "list_windows": return listWindows(s)
            case "screenshot": return try screenshot(s, args)
            case "click": return try click(s, args)
            case "type": return try type(s, args)
            case "key": return try key(s, args)
            case "scroll": return try scroll(s, args)
            case "drag": return try drag(s, args)
            case "menu": return try menu(s, args)
            case "zoom": return try zoom(s, args)
            case "find": return try find(s, args)
            default: return .error("unknown tool \"\(name)\"")
            }
        } catch let e as ToolError {
            return e.result
        } catch let e as CaptureError {
            return .error(Perm.screenOK ? e.message : Perm.screenMessage() + " (\(e.message))")
        } catch {
            return .error("\(error)")
        }
    }

    // MARK: Apps

    private func names(_ app: NSRunningApplication) -> [String] {
        [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0 }
    }

    private func denial(names: [String], bundleID: String?) -> String? {
        var last: String?
        for n in names {
            guard let d = ConfigStore.shared.denial(name: n, bundleID: bundleID) else { return nil }
            last = last ?? d
        }
        return last ?? "app has no name"
    }

    /// Apps abiertas. La lista de NSWorkspace se actualiza con retraso, así que se completa con las
    /// que abrió open_app y, si hace falta, con los dueños de las ventanas que hay ahora mismo.
    private func candidates(fresh: Bool) -> [NSRunningApplication] {
        var byPid: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy != .prohibited { byPid[a.processIdentifier] = a }
        for a in launched where byPid[a.processIdentifier] == nil { byPid[a.processIdentifier] = a }
        if fresh, let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [JSON] {
            for pid in Set(list.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }) where byPid[pid] == nil {
                if let a = NSRunningApplication(processIdentifier: pid), a.activationPolicy != .prohibited { byPid[pid] = a }
            }
        }
        return byPid.values.filter { kill($0.processIdentifier, 0) == 0 }
    }

    private func runningApp(_ q: String) -> NSRunningApplication? {
        for fresh in [false, true] {
            let apps = candidates(fresh: fresh)
            if let pid = Int32(q) {
                if let a = apps.first(where: { $0.processIdentifier == pid }) { return a }
                continue
            }
            let l = q.lowercased()
            if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == l }) { return a }
            if let a = apps.first(where: { app in names(app).contains { $0.lowercased() == l } }) { return a }
            let partial = apps.filter { app in names(app).contains { $0.lowercased().contains(l) } }
            if partial.count == 1 { return partial[0] }
        }
        return nil
    }

    private func session(_ args: JSON) throws -> Session {
        guard let q = args.str("app"), !q.isEmpty else { throw ToolError("`app` is required (name, bundle id or pid; see list_apps)") }
        guard let app = runningApp(q) else { throw ToolError("\"\(q)\" is not running (or the name is ambiguous); use open_app or list_apps") }
        if let d = denial(names: names(app), bundleID: app.bundleIdentifier) { throw ToolError(d) }
        if app.isHidden { app.unhide() }
        let s = sessions[app.processIdentifier] ?? Session(app)
        sessions[app.processIdentifier] = s
        if !s.prepared, Perm.axOK {
            s.prepared = true
            // Una app colgada no debe retener cada llamada los 6 s que espera el sistema por defecto.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
            AXUIElementSetMessagingTimeout(s.appEl, 1.0)
            // Electron/Chromium/WebKit solo publican su árbol completo si se les pide explícitamente.
            axSet(s.appEl, "AXManualAccessibility", kCFBooleanTrue)
            axSet(s.appEl, "AXEnhancedUserInterface", kCFBooleanTrue)
        }
        return s
    }

    private func needAX() throws {
        if !Perm.axOK { throw ToolError(Perm.axMessage()) }
    }

    private func listApps() -> ToolResult {
        let apps = candidates(fresh: true).filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        var lines = apps.map { a -> String in
            let ok = denial(names: names(a), bundleID: a.bundleIdentifier) == nil
            return "\(ok ? "allowed" : "blocked") \(a.localizedName ?? "?") (\(a.bundleIdentifier ?? "?")) pid \(a.processIdentifier)\(a.isActive ? " frontmost" : "")\(a.isHidden ? " hidden" : "")"
        }
        let running = Set(apps.flatMap { names($0) + [$0.bundleIdentifier ?? ""] }.map { $0.lowercased() })
        let idle = ConfigStore.shared.load().allowedApps.filter { !running.contains($0.lowercased()) }
        if !idle.isEmpty { lines.append("allowed but not running (open_app): " + idle.joined(separator: ", ")) }
        if !Perm.axOK { lines.append("note: " + Perm.axMessage()) }
        if !Perm.screenOK { lines.append("note: " + Perm.screenMessage()) }
        return .plain(lines.joined(separator: "\n"))
    }

    private func locateApp(_ q: String) -> URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) { return u }
        let l = q.lowercased().replacingOccurrences(of: ".app", with: "")
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".app") {
                let path = d + "/" + f
                let shown = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                if (f as NSString).deletingPathExtension.lowercased() == l || shown.lowercased() == l { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// Oculta el cursor fantasma al terminar la tarea (llamado por el agente).
    private func hideCursor() -> ToolResult {
        PhantomCursor.shared.dismiss()
        return .ok("floating cursor hidden; it will reappear on the next action")
    }

    private func openApp(_ args: JSON) throws -> ToolResult {
        guard let q = args.str("app"), !q.isEmpty else { throw ToolError("`app` is required") }
        if let app = runningApp(q) {
            if let d = denial(names: names(app), bundleID: app.bundleIdentifier) { throw ToolError(d) }
            if app.isHidden { app.unhide() }
            let n = cgWindows(pid: app.processIdentifier, all: true).count
            if n > 0 { return .ok("\(app.localizedName ?? q) already running, pid \(app.processIdentifier), \(n) window(s); it was not brought to front") }
        }
        guard let url = runningApp(q)?.bundleURL ?? locateApp(q) else { throw ToolError("app \"\(q)\" not found in /Applications or /System/Applications") }
        let appNames = [url.deletingPathExtension().lastPathComponent, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")]
        if let d = denial(names: appNames, bundleID: Bundle(url: url)?.bundleIdentifier) { throw ToolError(d) }

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        let sem = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var failure: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
            launched = app
            failure = error
            sem.signal()
        }
        if sem.wait(timeout: .now() + 15) == .timedOut { throw ToolError("launching \(appNames[0]) timed out") }
        guard let app = launched else { throw ToolError("could not launch \(appNames[0]): \(failure?.localizedDescription ?? "unknown error")") }
        self.launched = self.launched.filter { !$0.isTerminated && $0.processIdentifier != app.processIdentifier } + [app]
        // Espera breve a que aparezca la primera ventana.
        var n = 0
        for _ in 0..<20 {
            n = cgWindows(pid: app.processIdentifier, all: true).count
            if n > 0 { break }
            usleep(100_000)
        }
        return .ok("\(app.localizedName ?? appNames[0]) open in background, pid \(app.processIdentifier), \(n) window(s)")
    }

    // MARK: Ventanas

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    private func axWindows(_ s: Session) -> [AXUIElement] {
        var w = axChildren(s.appEl, kAXWindowsAttribute)
        for k in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let e = axElement(s.appEl, k), !w.contains(where: { CFEqual($0, e) }) { w.append(e) }
        }
        return w
    }

    /// Ventana de accesibilidad que corresponde a una ventana del servidor gráfico:
    /// primero usa `_AXUIElementGetWindow` (exacto, como `computer_use.node`), y como fallback compara marco y título.
    private func matchAX(_ s: Session, _ win: WinInfo) -> AXUIElement? {
        let candidates = axWindows(s)
        for w in candidates {
            if SkyLight.windowID(for: w) == win.id { return w }
        }
        var best: AXUIElement?
        for w in candidates {
            guard let f = axFrame(w), near(f, win.bounds) else { continue }
            if win.title.isEmpty || axStr(w, kAXTitleAttribute) == win.title { return w }
            best = best ?? w
        }
        return best
    }

    /// Si la ventana AX está minimizada, la desminimiza en segundo plano sin robar el foco.
    private func unminimizeIfNeeded(_ s: Session, _ win: WinInfo) -> WinInfo {
        guard Perm.axOK, let axw = matchAX(s, win),
              (axAttr(axw, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true
        else { return win }
        axSet(axw, kAXMinimizedAttribute, kCFBooleanFalse)
        for _ in 0..<8 {
            usleep(40_000)
            if let updated = cgWindow(id: win.id, pid: s.pid), updated.onScreen {
                return updated
            }
        }
        return cgWindow(id: win.id, pid: s.pid) ?? win
    }

    /// `follow`: sin window_id, sigue a la ventana con foco (screenshot); si no, se queda en la del último screenshot.
    private func resolveWindow(_ s: Session, _ args: JSON, follow: Bool) throws -> WinInfo {
        if let id = args.int("window_id") {
            guard id > 0, let w = cgWindow(id: CGWindowID(id), pid: s.pid) else {
                throw ToolError("window_id \(id) not found in \(s.name); use list_windows")
            }
            return unminimizeIfNeeded(s, w)
        }
        if !follow, let cur = s.window {
            guard let w = cgWindow(id: cur.id, pid: s.pid) else { throw ToolError("the window from the last screenshot was closed; take a new screenshot") }
            return unminimizeIfNeeded(s, w)
        }
        var wins = cgWindows(pid: s.pid)
        if wins.isEmpty { wins = cgWindows(pid: s.pid, all: true) }
        guard !wins.isEmpty else { throw ToolError("\(s.name) has no windows; use open_app or the menu tool to open one") }
        if Perm.axOK {
            for k in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let e = axElement(s.appEl, k) {
                    if let wid = SkyLight.windowID(for: e), let w = wins.first(where: { $0.id == wid }) {
                        return unminimizeIfNeeded(s, w)
                    }
                    if let f = axFrame(e), let w = wins.first(where: { near($0.bounds, f) }) {
                        return unminimizeIfNeeded(s, w)
                    }
                }
            }
        }
        return unminimizeIfNeeded(s, wins[0])
    }

    private func bind(_ s: Session, _ win: WinInfo) {
        if s.window?.id != win.id {
            s.nodes = []
            s.texts = []
            s.axWindow = nil
        }
        s.window = win
        if s.axWindow == nil, Perm.axOK { s.axWindow = matchAX(s, win) }
    }

    private func listWindows(_ s: Session) -> ToolResult {
        let wins = cgWindows(pid: s.pid, all: true)
        if wins.isEmpty { return .plain("\(s.name) has no windows") }
        let axList = Perm.axOK ? axWindows(s) : []
        let lines = wins.map { w -> String in
            let axw = axList.first(where: { SkyLight.windowID(for: $0) == w.id })
                ?? axList.first(where: { axFrame($0).map { near($0, w.bounds) } ?? false })
            let axTitle = axw.flatMap { axStr($0, kAXTitleAttribute) } ?? ""
            let minimized = axw.flatMap { (axAttr($0, kAXMinimizedAttribute) as? NSNumber)?.boolValue } ?? false
            let title = w.title.isEmpty ? axTitle : w.title
            return "window_id=\(w.id) \"\(truncate(title, 60))\" \(Int(w.bounds.width))x\(Int(w.bounds.height))\(minimized ? " minimized" : w.onScreen ? "" : " not on screen")"
        }
        return .plain(lines.joined(separator: "\n"))
    }

    // MARK: screenshot

    private func line(_ i: Int, _ n: Node, _ win: WinInfo) -> String {
        var s = "[\(i)] \(nodeTitle(n)) @\(Int(n.frame.midX - win.bounds.minX)),\(Int(n.frame.midY - win.bounds.minY)) \(Int(n.frame.width))x\(Int(n.frame.height))"
        if let v = n.value, v != n.label { s += n.isSecure ? " =•••" : " =\"\(truncate(v, 30))\"" }
        if n.focused { s += " focused" }
        if !n.enabled { s += " disabled" }
        return s
    }

    private func screenshot(_ s: Session, _ args: JSON) throws -> ToolResult {
        let t0 = nowMs()
        let cfg = ConfigStore.shared.load()
        let win = try resolveWindow(s, args, follow: true)
        bind(s, win)
        s.axWindow = Perm.axOK ? matchAX(s, win) : nil

        // Despierta el compositor en background (Chromium/Electron) antes de capturar
        if SkyLight.beginKeyWindowSpoof(pid: s.pid, windowID: win.id) {
            SkyLight.endKeyWindowSpoof(pid: s.pid, windowID: win.id)
        }

        let (w, h) = (win.bounds.width, win.bounds.height)
        let scale = args.num("scale").map { clamp($0, 0.1, 1) } ?? min(1, cfg.maxImageEdge / max(w, h))

        // La captura corre en paralelo con el recorrido de accesibilidad.
        var image: CGImage?
        var captureError: String?
        var captureMs = 0.0
        let sem = DispatchSemaphore(value: 0)
        let tryCapture = Perm.screenOK || !Perm.noPrompt
        if tryCapture {
            DispatchQueue.global(qos: .userInitiated).async {
                let c0 = nowMs()
                do {
                    image = try self.capturer.capture(win.id, pixelWidth: Int((w * scale).rounded()), pixelHeight: Int((h * scale).rounded()))
                } catch let e as CaptureError {
                    captureError = e.message
                } catch {
                    captureError = "\(error)"
                }
                captureMs = nowMs() - c0
                sem.signal()
            }
        }

        var walk: Walk?
        if let axw = s.axWindow {
            var r = walkWindow(axw, frame: win.bounds, budgetMs: cfg.axBudgetMs)
            // Si la ventana acaba de recibir AXManualAccessibility (Electron/WebKit) y aún no pobló sus nodos,
            // esperamos brevemente igual que `waitUntilWebTreeIsReady` en Claude Desktop.
            if r.actionable.isEmpty && r.visited <= 5 {
                for _ in 0..<4 {
                    usleep(60_000)
                    r = walkWindow(axw, frame: win.bounds, budgetMs: cfg.axBudgetMs)
                    if !r.actionable.isEmpty || r.visited > 5 { break }
                }
            }
            s.nodes = r.actionable
            s.texts = r.texts
            walk = r
        } else {
            s.nodes = []
            s.texts = []
        }
        if tryCapture { sem.wait() }

        let e0 = nowMs()
        let encoded = image.flatMap { encodeImage($0, jpegQuality: cfg.jpegQuality) }
        let encodeMs = nowMs() - e0

        var title = win.title
        if title.isEmpty, let axw = s.axWindow { title = axStr(axw, kAXTitleAttribute) ?? "" }
        var lines = ["\(s.name) \"\(truncate(title, 60))\" window_id=\(win.id)\(win.onScreen ? "" : " (not on screen: the image may be stale)")"]
        var frameLine = "frame \(Int(w))x\(Int(h)): coordinates are window points in this frame, origin top-left"
        if let image {
            frameLine += "; image \(image.width)x\(image.height) (scale \(String(format: "%.2f", scale)))"
            if scale < 1 { frameLine += ", multiply image pixels by \(String(format: "%.2f", 1 / scale)) to get coordinates" }
        }
        lines.append(frameLine)
        if image == nil {
            lines.append("image: none. " + (Perm.screenOK ? (captureError ?? "capture failed") : Perm.screenMessage()))
        }
        if walk != nil {
            for (i, n) in s.nodes.prefix(cfg.maxElements).enumerated() { lines.append(line(i + 1, n, win)) }
            if s.nodes.count > cfg.maxElements { lines.append("+\(s.nodes.count - cfg.maxElements) more elements not listed; use find") }
            if s.nodes.isEmpty { lines.append("no actionable elements exposed; act by coordinate") }
        } else if !Perm.axOK {
            lines.append("elements: none. " + Perm.axMessage())
        } else {
            lines.append("elements: none (no accessibility window matches this one; act by coordinate)")
        }
        let others = cgWindows(pid: s.pid).filter { $0.id != win.id }
        if !others.isEmpty {
            lines.append("other windows: " + others.prefix(6).map { "\($0.id)\($0.title.isEmpty ? "" : " \"\(truncate($0.title, 30))\"")" }.joined(separator: ", "))
        }
        var timing = "timing: capture \(Int(captureMs)) ms, ax \(Int(walk?.ms ?? 0)) ms (\(walk?.visited ?? 0) nodes\(walk?.truncated == true ? ", cut by budget" : "")), encode \(Int(encodeMs)) ms, total \(Int(nowMs() - t0)) ms"
        if let d = encoded?["data"] as? String { timing += ", image \(d.count * 3 / 4 / 1024) KB" }
        lines.append(timing)

        if image == nil, walk == nil { return .error(lines.dropFirst(2).joined(separator: "\n")) }
        var r = ToolResult.plain(lines.joined(separator: "\n"))
        if let encoded { r.extra = [encoded] }
        return r
    }

    // MARK: Objetivo de una acción

    private func pointTarget(_ s: Session, _ win: WinInfo, _ p: CGPoint, how: String) -> Target {
        let sp = CGPoint(x: win.bounds.minX + p.x, y: win.bounds.minY + p.y)
        var t = Target(el: nil, node: nil, winPoint: p, screenPoint: sp, how: how, win: win)
        guard Perm.axOK else { return t }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(s.appEl, Float(sp.x), Float(sp.y), &hit) == .success, let el = hit else { return t }
        // Si otra ventana de la misma app tapa ese punto, el elemento no es de la nuestra.
        if let mine = s.axWindow, let theirs = axElement(el, kAXWindowAttribute), !CFEqual(mine, theirs) { return t }
        t.el = el
        t.node = describe(el)
        return t
    }

    private func focusedTarget(_ s: Session, _ win: WinInfo) -> Target {
        var t = Target(el: nil, node: nil, winPoint: nil, screenPoint: nil, how: "focused", win: win)
        var resolved = axElement(s.appEl, kAXFocusedUIElementAttribute)
        if let r = resolved, (axStr(r, kAXRoleAttribute) ?? "") == "AXWindow" {
            resolved = nil
        }
        if resolved == nil {
            resolved = findTargetTextElement(appAX: s.appEl, winAX: s.axWindow)
        }
        guard let el = resolved else { return t }
        let n = describe(el)
        t.el = el
        t.node = n
        if !n.frame.isNull, n.frame.width > 0 {
            let f = n.frame.intersection(win.bounds).isNull ? n.frame : n.frame.intersection(win.bounds)
            t.screenPoint = CGPoint(x: f.midX, y: f.midY)
            t.winPoint = CGPoint(x: f.midX - win.bounds.minX, y: f.midY - win.bounds.minY)
        }
        return t
    }

    /// element_index, coordinate o target:"focused"; si no viene ninguno, el punto de la acción anterior en esa ventana.
    private func target(_ s: Session, _ args: JSON, allowDefault: Bool = true) throws -> Target {
        let win = try resolveWindow(s, args, follow: false)
        bind(s, win)
        if args["element_index"] != nil {
            guard let i = args.int("element_index"), i >= 1, i <= s.nodes.count else {
                throw ToolError("element_index is not in the last screenshot (valid: 1…\(s.nodes.count)); take a screenshot first")
            }
            let el = s.nodes[i - 1].el
            var n = describe(el)
            if n.role == "AXUnknown", n.frame.isNull { throw ToolError("element [\(i)] no longer exists; take a new screenshot") }
            if n.label.isEmpty { n.label = s.nodes[i - 1].label }
            var t = Target(el: el, node: n, winPoint: nil, screenPoint: nil, how: "index", win: win)
            if !n.frame.isNull, n.frame.width > 0 {
                let vis = n.frame.intersection(win.bounds)
                let f = vis.isNull || n.role == "AXMenuItem" ? n.frame : vis
                t.screenPoint = CGPoint(x: f.midX, y: f.midY)
                t.winPoint = CGPoint(x: f.midX - win.bounds.minX, y: f.midY - win.bounds.minY)
            }
            return t
        }
        if args["coordinate"] != nil {
            guard let p = args.point("coordinate") else { throw ToolError("coordinate must be [x, y]") }
            guard p.x >= 0, p.y >= 0, p.x <= win.bounds.width, p.y <= win.bounds.height else {
                throw ToolError("coordinate (\(Int(p.x)),\(Int(p.y))) is outside the frame \(Int(win.bounds.width))x\(Int(win.bounds.height)); coordinates are window points, not image pixels")
            }
            return pointTarget(s, win, p, how: "coordinate")
        }
        if let t = args.str("target") {
            guard t.lowercased() == "focused" else { throw ToolError("target only accepts \"focused\"") }
            return focusedTarget(s, win)
        }
        guard allowDefault else { throw ToolError("no target: pass element_index or coordinate") }
        if let p = s.lastPoint[win.id] { return pointTarget(s, win, p, how: "last") }
        return focusedTarget(s, win)
    }

    private func ensureMain(_ s: Session) {
        guard let w = s.axWindow, (axAttr(w, kAXMainAttribute) as? NSNumber)?.boolValue == false else { return }
        axSet(w, kAXMainAttribute, kCFBooleanTrue)
    }

    // MARK: click

    private func press(_ el: AXUIElement, role: String, label: String) -> ToolResult? {
        guard axActions(el).contains(kAXPressAction) else { return nil }
        switch axPerform(el, kAXPressAction) {
        case .done:
            let menu = role == "AXPopUpButton" || role == "AXMenuButton"
            return .ok("AXPress \(label)" + (menu ? "; its menu opened: take a screenshot and click the menuitem by element_index" : ""))
        case .pending:
            return .ok("AXPress \(label) sent; the app is still handling it (a menu or modal dialog probably opened), take a screenshot")
        case .failed:
            return nil
        }
    }

    /// Detecta si tras un clic se abrieron nuevos elementos (como un menú desplegable o popover),
    /// actualiza `s.nodes` y devuelve el listado compacto de los nuevos `[N]` para evitar un `screenshot` extra.
    private func appendPostClickChanges(_ s: Session, _ t: Target, into result: ToolResult) -> ToolResult {
        guard result.status == .ok, Perm.axOK, let axw = s.axWindow else { return result }
        let oldSignatures = Set(s.nodes.map { "\($0.role)|\($0.label)" })
        usleep(75_000)
        let r = walkWindow(axw, frame: t.win.bounds, budgetMs: 70)
        var added: [(Int, Node)] = []
        for (idx, node) in r.actionable.enumerated() {
            let sig = "\(node.role)|\(node.label)"
            if !oldSignatures.contains(sig) && (node.role == "AXMenuItem" || !node.label.isEmpty) {
                added.append((idx + 1, node))
            }
        }
        guard !added.isEmpty else { return result }
        s.nodes = r.actionable
        s.texts = r.texts
        var out = result
        let preview = added.prefix(20).map { (i, n) in line(i, n, t.win) }.joined(separator: "\n")
        out.text += "\nopened/new elements (click directly by element_index):\n" + preview
        return out
    }

    /// Clic izquierdo por accesibilidad; nil si hay que caer al evento de ratón.
    private func axClick(_ s: Session, _ el: AXUIElement, _ n: Node, _ t: Target, count: Int = 1) -> ToolResult? {
        let name = nodeTitle(n)
        if textRoles.contains(n.role) {
            let focused = axSet(el, kAXFocusedAttribute, kCFBooleanTrue) == .success
            if t.how == "index", count == 1 { return focused ? .ok("focused \(name)") : nil }
            if let sp = t.screenPoint {
                // Primero intentamos posicionamiento de cursor / selección de palabra o línea vía AXRangeForPosition
                if clickTextElementViaAX(el, at: sp, count: count) {
                    let actionDesc = count == 1 ? "placed caret" : count == 2 ? "selected word" : "selected line"
                    return .ok("focused \(name) and \(actionDesc) via AXRangeForPosition")
                }
                guard focused else { return nil }
                postClick(pid: s.pid, at: sp, button: "left", count: count, flags: [], window: t.win.id, windowBounds: t.win.bounds)
                return .ok("focused \(name) and clicked (x\(count)) with a background mouse event")
            }
            return nil
        }
        guard count == 1 else { return nil }
        if let r = press(el, role: n.role, label: name) { return r }
        if n.role == "AXRow", axSet(el, kAXSelectedAttribute, kCFBooleanTrue) == .success { return .ok("selected \(name)") }
        guard t.how != "index" else { return nil }
        // El punto cayó en un texto o imagen dentro de algo pulsable.
        var cur = axElement(el, kAXParentAttribute)
        var hops = 0
        while let c = cur, hops < 4 {
            let role = axStr(c, kAXRoleAttribute) ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            if pressRoles.contains(role), let r = press(c, role: role, label: nodeTitle(describe(c))) { return r }
            if role == "AXRow", axSet(c, kAXSelectedAttribute, kCFBooleanTrue) == .success { return .ok("selected row under \(name)") }
            cur = axElement(c, kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    private func click(_ s: Session, _ args: JSON) throws -> ToolResult {
        try needAX()
        let button = (args.str("button") ?? "left").lowercased()
        guard ["left", "right", "middle"].contains(button) else { throw ToolError("button must be left, right or middle") }
        let count = clamp(args.int("count") ?? 1, 1, 3)
        guard let flags = parseModifiers(args["modifiers"]) else { throw ToolError("unknown modifier; use cmd, shift, alt, ctrl") }
        let t = try target(s, args)
        if let p = t.winPoint { s.lastPoint[t.win.id] = p }
        let name = t.node.map(nodeTitle) ?? "point"

        // Mostrar cursor fantasma animado con pulso en el punto objetivo (sin mover el cursor real)
        if let sp = t.screenPoint {
            let glideMs = PhantomCursor.shared.show(at: sp, windowID: t.win.id, pulse: true)
            if glideMs > 40 {
                usleep(useconds_t(min(220_000, glideMs * 850)))
            }
        }

        if let el = t.el, let n = t.node {
            if !n.enabled { return .unsupported("\(name) is disabled; change whatever enables it first") }
            if n.role == "AXMenuBarItem" || n.role == "AXMenuBar" { return .unsupported("menu bar items are not clicked; use the menu tool with path") }
            if button == "left", flags.isEmpty, let r = axClick(s, el, n, t, count: count) {
                return appendPostClickChanges(s, t, into: r)
            }
            if button == "right", count == 1, flags.isEmpty, axActions(el).contains(kAXShowMenuAction) {
                if case .failed = axPerform(el, kAXShowMenuAction) {} else {
                    let res = ToolResult.ok("AXShowMenu on \(name): context menu opened")
                    return appendPostClickChanges(s, t, into: res)
                }
            }
        }
        guard let sp = t.screenPoint, let wp = t.winPoint else {
            return .unsupported("\(name) has no position on screen; target it by coordinate from a screenshot")
        }
        postClick(pid: s.pid, at: sp, button: button, count: count, flags: flags, window: t.win.id, windowBounds: t.win.bounds)
        let res = ToolResult.ok("\(button) click\(count > 1 ? " x\(count)" : "") at (\(Int(wp.x)),\(Int(wp.y))) on \(name) via background mouse event; not verifiable here, take a screenshot to confirm")
        return appendPostClickChanges(s, t, into: res)
    }

    // MARK: type

    private func type(_ s: Session, _ args: JSON) throws -> ToolResult {
        try needAX()
        guard let text = args.str("text"), !text.isEmpty else { throw ToolError("`text` is required") }
        let overwrite = (args.bool("overwrite_existing") ?? false)
            || (args.bool("clear") ?? false)
            || (args.str("mode")?.lowercased() == "replace")
        var t = try target(s, args)
        // Sin objetivo explícito, si en el punto anterior no hay un campo de texto se escribe donde está el foco.
        if t.how == "last", !(t.node.map { textRoles.contains($0.role) } ?? false) { t = focusedTarget(s, t.win) }
        let chars = (text as NSString).length
        if let sp = t.screenPoint {
            PhantomCursor.shared.show(at: sp, windowID: t.win.id, pulse: false)
        }

        guard let el = t.el, let n = t.node else {
            if t.how == "focused" {
                ensureMain(s)
                postText(pid: s.pid, text)
                return .ok("typed \(chars) chars via background key events (the app exposes no focused element to verify); take a screenshot to confirm")
            }
            return .unsupported("no accessibility element at that point; click the field first, then type with target:\"focused\"")
        }
        let name = nodeTitle(n)
        if n.isSecure { return .unsupported("\(name) is a password field; Marco must type it himself") }
        if !n.enabled { return .unsupported("\(name) is disabled") }

        let editable = textRoles.contains(n.role) || axSettable(el, kAXSelectedTextAttribute)
        if !editable {
            if t.how == "focused" || n.focused {
                ensureMain(s)
                postText(pid: s.pid, text)
                return .ok("typed \(chars) chars into focused \(name) via background key events; not verifiable here, take a screenshot to confirm")
            }
            return .unsupported("\(name) is not an editable text element; use the element_index of a textfield, or click it by coordinate and type with target:\"focused\"")
        }

        func value() -> String? { axAttr(el, kAXValueAttribute) as? String }
        let before = value()
        let beforeLen = ((before ?? "") as NSString).length
        if !n.focused { axSet(el, kAXFocusedAttribute, kCFBooleanTrue) }

        if overwrite {
            if axSet(el, kAXValueAttribute, text as CFString) == .success, value() == text {
                return .ok("replaced the contents of \(name) via AXValue (\(chars) chars)")
            }
            if axSetRange(el, 0, beforeLen) == .success, axSet(el, kAXSelectedTextAttribute, text as CFString) == .success, value() == text {
                return .ok("replaced the contents of \(name) via AXSelectedText (\(chars) chars)")
            }
            ensureMain(s)
            postKey(pid: s.pid, combo: KeyCombo(flags: .maskCommand, code: keyCodes["a"], char: "a"))
            postText(pid: s.pid, text)
            usleep(120_000)
            if value() == text { return .ok("replaced the contents of \(name) via background key events (\(chars) chars)") }
            return .ineffective("\(name) accepted the write but its value is not the new text; click it by coordinate so it takes real focus, then retry")
        }

        if beforeLen > 0 {
            if n.focused {
                if let sel = asRange(axAttr(el, kAXSelectedTextRangeAttribute)), sel.location == 0, sel.length >= beforeLen {
                    return .unsupported("the whole content of \(name) is selected, so typing would replace it; pass overwrite_existing:true, or send key \"right\" to keep it and append")
                }
            } else {
                // Al enfocar, muchos campos seleccionan todo: el cursor va al final para añadir, no reemplazar.
                _ = axSetRange(el, beforeLen, 0)
            }
        }
        let err = axSet(el, kAXSelectedTextAttribute, text as CFString)
        if err == .success {
            if before == nil, value() == nil { return .ok("typed \(chars) chars into \(name) via AXSelectedText (value not readable; take a screenshot to confirm)") }
            for _ in 0..<2 {
                if value() != before { return .ok("typed \(chars) chars into \(name) via AXSelectedText (now \(((value() ?? "") as NSString).length) chars)") }
                usleep(40_000)
            }
        }
        if beforeLen == 0, axSet(el, kAXValueAttribute, text as CFString) == .success, value() == text {
            return .ok("typed \(chars) chars into \(name) via AXValue")
        }
        ensureMain(s)
        postText(pid: s.pid, text)
        usleep(120_000)
        if value() != before { return .ok("typed \(chars) chars into \(name) via background key events (now \(((value() ?? "") as NSString).length) chars)") }
        return .ineffective("\(name) accepted the text but its value did not change; click it by coordinate so it takes real focus, then type with target:\"focused\"")
    }

    // MARK: key

    /// Ítem de la barra de menús con ese atajo de teclado, y su ruta.
    private func findShortcut(_ s: Session, _ c: KeyCombo) -> (MenuEntry, String)? {
        guard let bar = axElement(s.appEl, kAXMenuBarAttribute) else { return nil }
        let want = (c.flags.contains(.maskShift) ? 1 : 0) | (c.flags.contains(.maskAlternate) ? 2 : 0) | (c.flags.contains(.maskControl) ? 4 : 0)
        let deadline = nowMs() + 250
        func search(_ container: AXUIElement, _ path: [String], _ depth: Int) -> (MenuEntry, String)? {
            for e in menuEntries(container) {
                if nowMs() > deadline { return nil }
                if e.cmdChar.lowercased() == c.char, e.cmdMods == want { return (e, (path + [e.title]).joined(separator: " > ")) }
                if e.hasSubmenu, depth < 2, let r = search(e.el, path + [e.title], depth + 1) { return r }
            }
            return nil
        }
        return search(bar, [], 0)
    }

    private func key(_ s: Session, _ args: JSON) throws -> ToolResult {
        try needAX()
        guard let keys = args.str("keys") ?? args.str("key"), !keys.isEmpty else { throw ToolError("`keys` is required, e.g. \"return\" or \"cmd+s\"") }
        var combos: [(String, KeyCombo)] = []
        for part in keys.split(separator: " ") {
            guard let c = parseCombo(String(part)) else {
                throw ToolError("unknown key \"\(part)\"; examples: return, tab, escape, delete, left, pagedown, f5, cmd+s, cmd+shift+z")
            }
            combos.append((String(part).lowercased(), c))
        }
        var targetEl: AXUIElement?
        if args["element_index"] != nil || args["coordinate"] != nil {
            if let el = try target(s, args).el {
                axSet(el, kAXFocusedAttribute, kCFBooleanTrue)
                targetEl = el
            }
        } else {
            bind(s, try resolveWindow(s, args, follow: false))
        }
        if targetEl == nil {
            targetEl = findTargetTextElement(appAX: s.appEl, winAX: s.axWindow)
        }
        let secure = (targetEl ?? axElement(s.appEl, kAXFocusedUIElementAttribute)).map { axStr($0, kAXSubroleAttribute) == "AXSecureTextField" } ?? false

        var done: [String] = []
        var events = false
        for (name, c) in combos {
            if secure, !["return", "enter", "tab", "escape", "esc"].contains(c.char) {
                return .unsupported("the focus is in a password field; only return, tab and escape are sent there. Marco must type the password himself")
            }
            // 1. cmd+a en background: selecciona todo directamente sobre el elemento de texto (incluso sin foco del sistema).
            if c.flags == .maskCommand, c.char == "a",
               let el = targetEl ?? findTargetTextElement(appAX: s.appEl, winAX: s.axWindow),
               axSelectAllText(el)
            {
                let len = ((axAttr(el, kAXValueAttribute) as? String ?? "") as NSString).length
                done.append("cmd+a → selected all \(len) chars via AXSelectedTextRange")
                continue
            }
            // 2. delete / backspace / forwarddelete sin modificadores sobre un control de texto en background.
            if c.flags.isEmpty, ["delete", "backspace", "forwarddelete"].contains(c.char),
               let el = targetEl ?? findTargetTextElement(appAX: s.appEl, winAX: s.axWindow),
               axDeleteText(el, forward: c.char == "forwarddelete")
            {
                done.append("\(name) → deleted via AXSelectedText")
                continue
            }
            // 3. return / enter sin modificadores sobre un AXTextArea multilínea en background.
            if c.flags.isEmpty, ["return", "enter"].contains(c.char),
               let el = targetEl ?? findTargetTextElement(appAX: s.appEl, winAX: s.axWindow),
               axStr(el, kAXRoleAttribute) == "AXTextArea",
               axSettable(el, kAXSelectedTextAttribute),
               axSet(el, kAXSelectedTextAttribute, "\n" as CFString) == .success
            {
                done.append("\(name) → inserted newline via AXSelectedText")
                continue
            }
            // 4. Un atajo con cmd se resuelve pulsando su ítem de menú: si está deshabilitado por estar en background,
            // usamos keyWindowSpoof (como app-cu-helper en Claude Desktop) para habilitar el Responder Chain sin robar foco.
            if c.flags.contains(.maskCommand), c.char.count == 1, let (initialEntry, path) = findShortcut(s, c) {
                var entry = initialEntry
                if !entry.enabled {
                    let pressedInSpoof = SkyLight.withKeyWindowSpoof(pid: s.pid, windowID: s.window?.id) { () -> Bool in
                        for _ in 0..<4 {
                            if let (rechecked, _) = findShortcut(s, c), rechecked.enabled {
                                entry = rechecked
                                if case .failed = axPerform(entry.el, kAXPressAction) { return false }
                                return true
                            }
                            usleep(35_000)
                        }
                        return false
                    }
                    if pressedInSpoof {
                        done.append("\(name) → menu \"\(path)\"")
                        continue
                    }
                    return .unsupported("\(name) is the menu item \"\(path)\", which is disabled right now (with the app in the background, items that act on the selection can show as disabled; for text use type, for select-all use cmd+a on a focused text element)")
                }
                if case .failed = axPerform(entry.el, kAXPressAction) {} else {
                    done.append("\(name) → menu \"\(path)\"")
                    continue
                }
            }
            ensureMain(s)
            postKey(pid: s.pid, combo: c)
            usleep(15000)
            done.append(name)
            events = true
        }
        return .ok("keys: " + done.joined(separator: ", ") + (events ? " (sent as background key events; take a screenshot to confirm)" : ""))
    }

    // MARK: scroll

    private func scroll(_ s: Session, _ args: JSON) throws -> ToolResult {
        try needAX()
        guard let dir = args.str("direction")?.lowercased(), ["up", "down", "left", "right"].contains(dir) else {
            throw ToolError("`direction` must be up, down, left or right")
        }
        let amount = clamp(args.num("amount") ?? 3, 0.1, 100)
        let vertical = dir == "up" || dir == "down"
        let sign: Double = (dir == "down" || dir == "right") ? 1 : -1
        let t = try target(s, args)
        if let p = t.winPoint { s.lastPoint[t.win.id] = p }
        if let sp = t.screenPoint {
            let glideMs = PhantomCursor.shared.show(at: sp, windowID: t.win.id, pulse: false)
            if glideMs > 40 {
                usleep(useconds_t(min(160_000, glideMs * 800)))
            }
        }

        // Área de scroll que contiene el objetivo.
        var area: AXUIElement?
        var cur = t.el
        var hops = 0
        while let c = cur, hops < 15 {
            if axStr(c, kAXRoleAttribute) == "AXScrollArea" {
                area = c
                break
            }
            cur = axElement(c, kAXParentAttribute)
            hops += 1
        }
        if let area, let bar = axElement(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
            let old = (axAttr(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
        {
            // Un tick = 15 % de lo visible. El tamaño del pulgar respecto a la barra dice cuánto es "lo visible".
            var step = 0.05
            if let bf = axFrame(bar),
                let thumb = axChildren(bar).first(where: { axStr($0, kAXRoleAttribute) == "AXValueIndicator" }), let tf = axFrame(thumb)
            {
                let ratio = Double(vertical ? tf.height / max(bf.height, 1) : tf.width / max(bf.width, 1))
                if ratio > 0.001, ratio < 0.999 { step = 0.15 * ratio / (1 - ratio) }
            }
            let new = clamp(old + sign * amount * step, 0, 1)
            if abs(new - old) < 0.0005 { return .ok("already at the \(dir == "down" ? "bottom" : dir == "up" ? "top" : dir + " edge"); scroll position \(String(format: "%.2f", old))") }
            axSet(bar, kAXValueAttribute, NSNumber(value: new))
            usleep(20000)
            if let after = (axAttr(bar, kAXValueAttribute) as? NSNumber)?.doubleValue, abs(after - old) > 0.0005 {
                return .ok("scrolled \(dir) via AXScrollBar: position \(String(format: "%.2f", old)) → \(String(format: "%.2f", after)) (0 = start, 1 = end)")
            }
        }
        guard let sp = t.screenPoint else {
            return .unsupported("no scroll area found for that target; pass a coordinate inside the content to scroll")
        }
        let px = Int32((amount * 60).rounded())
        postScroll(
            pid: s.pid, at: sp,
            dx: vertical ? 0 : Int32(-sign) * px,
            dy: vertical ? Int32(-sign) * px : 0,
            window: t.win.id, windowBounds: t.win.bounds
        )
        return .ok("scrolled \(dir) ~\(px) px via background scroll event; not verifiable here, take a screenshot to confirm")
    }

    // MARK: drag

    private func drag(_ s: Session, _ args: JSON) throws -> ToolResult {
        try needAX()
        guard let flags = parseModifiers(args["modifiers"]) else { throw ToolError("unknown modifier; use cmd, shift, alt, ctrl") }
        let from = try target(s, args)
        var toArgs: JSON = [:]
        if let i = args["to_element_index"] { toArgs["element_index"] = i }
        if let c = args["to"] { toArgs["coordinate"] = c }
        guard !toArgs.isEmpty else { throw ToolError("drag needs `to` ([x, y]) or `to_element_index`") }
        let to = try target(s, toArgs, allowDefault: false)
        guard let a = from.screenPoint, let b = to.screenPoint, let wa = from.winPoint, let wb = to.winPoint else {
            return .unsupported("start or end has no position on screen; give both as coordinates")
        }
        let glideA = PhantomCursor.shared.show(at: a, windowID: from.win.id, pulse: true)
        if glideA > 40 { usleep(useconds_t(min(180_000, glideA * 800))) }
        postDrag(pid: s.pid, from: a, to: b, flags: flags, window: from.win.id, windowBounds: from.win.bounds)
        let glideB = PhantomCursor.shared.show(at: b, windowID: from.win.id, pulse: true)
        if glideB > 40 { usleep(useconds_t(min(220_000, glideB * 850))) }
        s.lastPoint[from.win.id] = wb
        return .ok("dragged (\(Int(wa.x)),\(Int(wa.y))) → (\(Int(wb.x)),\(Int(wb.y))) via background mouse events; drags are the least reliable in background, take a screenshot to confirm")
    }

    // MARK: menu

    private func menu(_ s: Session, _ args: JSON) throws -> ToolResult {
        try needAX()
        guard let bar = axElement(s.appEl, kAXMenuBarAttribute) else { return .unsupported("\(s.name) exposes no menu bar; use screenshot and click") }
        var path = (args["path"] as? [Any])?.compactMap { $0 as? String } ?? args.str("path")?.components(separatedBy: ">") ?? []
        path = path.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let listOnly = args.bool("list") ?? false

        func walkMenuPath() throws -> (entries: [MenuEntry], walked: [String], leaf: MenuEntry?) {
            var curEntries = menuEntries(bar)
            var curWalked: [String] = []
            var curLeaf: MenuEntry?
            for part in path {
                var matched = matchMenuEntry(curEntries, target: part)
                if matched == nil {
                    let want = normTitle(part)
                    let m = curEntries.filter { normTitle($0.title).contains(want) }
                    if m.count == 1 { matched = m[0] }
                }
                guard let e = matched else {
                    let here = curWalked.isEmpty ? "the menu bar" : "\"" + curWalked.joined(separator: " > ") + "\""
                    throw ToolError("no item \"\(part)\" under \(here); available: " + curEntries.map(\.title).joined(separator: ", "))
                }
                curWalked.append(e.title)
                curLeaf = e
                curEntries = e.hasSubmenu ? menuEntries(e.el) : []
            }
            return (curEntries, curWalked, curLeaf)
        }

        var (entries, walked, leaf) = try walkMenuPath()
        var shown = walked.joined(separator: " > ")
        if let initialLeaf = leaf, !initialLeaf.hasSubmenu, !listOnly {
            if !initialLeaf.enabled {
                let winID = s.window?.id ?? (try? resolveWindow(s, args, follow: false).id)
                let spoofOutcome = try SkyLight.withKeyWindowSpoof(pid: s.pid, windowID: winID) { () -> PerformOutcome? in
                    for _ in 0..<5 {
                        let (_, w, l) = try walkMenuPath()
                        if let l, l.enabled {
                            shown = w.joined(separator: " > ")
                            leaf = l
                            return axPerform(l.el, kAXPressAction, timeout: 0.5)
                        }
                        usleep(35_000)
                    }
                    return nil
                }
                if let outcome = spoofOutcome {
                    switch outcome {
                    case .done: return .ok("menu \"\(shown)\"")
                    case .pending: return .ok("menu \"\(shown)\" sent; the app is still handling it (a dialog probably opened), take a screenshot")
                    case .failed(let e): return .error("AXPress on \"\(shown)\" failed (AXError \(e.rawValue))")
                    }
                }
                return .unsupported("menu item \"\(shown)\" is disabled right now")
            }
            switch axPerform(initialLeaf.el, kAXPressAction, timeout: 0.5) {
            case .done: return .ok("menu \"\(shown)\"")
            case .pending: return .ok("menu \"\(shown)\" sent; the app is still handling it (a dialog probably opened), take a screenshot")
            case .failed(let e): return .error("AXPress on \"\(shown)\" failed (AXError \(e.rawValue))")
            }
        }
        if let leaf, !leaf.hasSubmenu { return .plain("\"\(shown)\" is a command, not a submenu\(leaf.enabled ? "" : " (disabled)")") }
        if entries.isEmpty { return .plain("\"\(shown)\": empty (this submenu is only filled while it is open)") }
        let lines = entries.map { e -> String in
            let sc = shortcutText(e)
            return "\(e.mark.isEmpty ? "" : "✓ ")\(e.title)\(e.hasSubmenu ? " ▸" : "")\(sc.isEmpty ? "" : "  [\(sc)]")\(e.enabled ? "" : "  (disabled)")"
        }
        return .plain((walked.isEmpty ? "menu bar" : "\"\(shown)\"") + ":\n" + lines.joined(separator: "\n"))
    }

    // MARK: zoom

    private func zoom(_ s: Session, _ args: JSON) throws -> ToolResult {
        let win = try resolveWindow(s, args, follow: false)
        bind(s, win)
        guard let r = args.numbers("region"), r.count == 4 else { throw ToolError("`region` must be [x, y, width, height] in frame coordinates") }
        let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).intersection(CGRect(origin: .zero, size: win.bounds.size))
        guard !rect.isNull, rect.width >= 4, rect.height >= 4 else {
            throw ToolError("region is outside the frame \(Int(win.bounds.width))x\(Int(win.bounds.height))")
        }
        guard Perm.screenOK || !Perm.noPrompt else { return .error(Perm.screenMessage()) }
        let density = capturer.density(win.id)
        let full = try capturer.capture(win.id, pixelWidth: Int(win.bounds.width * density), pixelHeight: Int(win.bounds.height * density))
        let k = CGFloat(full.width) / win.bounds.width
        guard var crop = full.cropping(to: CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral) else {
            throw ToolError("could not crop that region")
        }
        let scale = clamp(args.num("scale") ?? 1, 0.1, 1)
        if scale < 1, let small = resized(crop, scale) { crop = small }
        guard let encoded = encodeImage(crop, jpegQuality: nil) else { throw ToolError("could not encode the image") }
        var res = ToolResult.plain("zoom of region \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) → image \(crop.width)x\(crop.height) px. Read-only: coordinates for actions still come from the screenshot frame")
        res.extra = [encoded]
        return res
    }

    private func resized(_ image: CGImage, _ scale: Double) -> CGImage? {
        let (w, h) = (max(Int(Double(image.width) * scale), 1), max(Int(Double(image.height) * scale), 1))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: find

    private func find(_ s: Session, _ args: JSON) throws -> ToolResult {
        guard let win = s.window, !(s.nodes.isEmpty && s.texts.isEmpty) else {
            throw ToolError("no elements cached for \(s.name); take a screenshot first")
        }
        var role = args.str("role")?.lowercased()
        if let r = role, r.hasPrefix("ax") { role = String(r.dropFirst(2)) }
        let q = args.str("title_contains")?.lowercased()
        guard role != nil || q != nil else { throw ToolError("pass role and/or title_contains") }
        func matches(_ n: Node) -> Bool {
            if let role, n.kind != role, n.role.lowercased() != "ax" + role { return false }
            if let q, !n.label.lowercased().contains(q), !(n.value?.lowercased().contains(q) ?? false) { return false }
            return true
        }
        var lines: [String] = []
        for (i, n) in s.nodes.enumerated() where matches(n) { lines.append(line(i + 1, n, win)) }
        for n in s.texts where matches(n) {
            lines.append("text \"\(truncate(n.value ?? n.label, 60))\" @\(Int(n.frame.midX - win.bounds.minX)),\(Int(n.frame.midY - win.bounds.minY)) (no index; click by coordinate)")
        }
        if lines.isEmpty { return .plain("no match in the last screenshot (\(s.nodes.count) elements, \(s.texts.count) texts); scroll or take a new screenshot") }
        let extra = lines.count > 40 ? "\n+\(lines.count - 40) more; narrow the search" : ""
        return .plain(lines.prefix(40).joined(separator: "\n") + extra)
    }

    // MARK: batch

    private func batch(_ args: JSON) throws -> ToolResult {
        guard let actions = args["actions"] as? [JSON], !actions.isEmpty else { throw ToolError("`actions` must be a non-empty array of {\"action\": ...}") }
        guard actions.count <= 30 else { throw ToolError("at most 30 actions per batch") }
        var result = ToolResult(status: .ok, text: "")
        var content: [JSON] = []
        var lines: [String] = []
        func flush() {
            if !lines.isEmpty { content.append(["type": "text", "text": lines.joined(separator: "\n")]) }
            lines = []
        }
        for (i, a) in actions.enumerated() {
            let name = a.str("action") ?? a.str("tool") ?? ""
            var sub = a
            if sub["app"] == nil { sub["app"] = args["app"] }
            let r: ToolResult
            switch name {
            case "wait":
                let ms = clamp(a.num("ms") ?? 300, 0, 3000)
                usleep(UInt32(ms * 1000))
                r = .ok("waited \(Int(ms)) ms")
            case "", "batch":
                r = .error("each action needs \"action\": click, type, key, scroll, drag, menu, screenshot, zoom, find, open_app or wait")
            default:
                r = run(name, sub)
            }
            lines.append("\(i + 1). \(name): \(r.text)")
            if !r.extra.isEmpty {
                flush()
                content += r.extra
            }
            if r.status != .ok {
                result.status = r.status
                if i < actions.count - 1 { lines.append("stopped: \(actions.count - 1 - i) action(s) not run") }
                break
            }
            if i < actions.count - 1 { usleep(30000) }
        }
        // El texto final queda en `text` para que lleve la latencia total.
        result.text = lines.joined(separator: "\n")
        result.extra = []
        result.prefix = content
        return result
    }
}
