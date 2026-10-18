import AppKit
import ApplicationServices
import Foundation

typealias JSON = [String: Any]

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

func log(_ s: String) {
    FileHandle.standardError.write(("[computer-use-mcp] " + s + "\n").data(using: .utf8)!)
}

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

func truncate(_ s: String, _ n: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
    return flat.count > n ? String(flat.prefix(n)) + "…" : flat
}

// MARK: - Argumentos

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }

    func num(_ k: String) -> Double? {
        if let s = self[k] as? String { return Double(s) }
        return (self[k] as? NSNumber)?.doubleValue
    }

    func int(_ k: String) -> Int? { num(k).map { Int($0.rounded()) } }

    func bool(_ k: String) -> Bool? {
        if let s = self[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return (self[k] as? NSNumber)?.boolValue
    }

    /// Lista de números: [x, y], {"x":..,"y":..} o "x,y".
    func numbers(_ k: String) -> [Double]? {
        if let a = self[k] as? [Any] {
            let n = a.compactMap { ($0 as? NSNumber)?.doubleValue ?? Double($0 as? String ?? "") }
            return n.count == a.count ? n : nil
        }
        if let d = self[k] as? JSON {
            let keys = ["x", "y", "width", "height"]
            let n = keys.compactMap { d.num($0) ?? d.num(String($0.prefix(1))) }
            return n.count >= 2 ? n : nil
        }
        if let s = self[k] as? String {
            let n = s.split(whereSeparator: { ", []()x".contains($0) }).compactMap { Double($0) }
            return n.isEmpty ? nil : n
        }
        return nil
    }

    func point(_ k: String) -> CGPoint? {
        guard let n = numbers(k), n.count >= 2 else { return nil }
        return CGPoint(x: n[0], y: n[1])
    }
}

// MARK: - Resultados

enum Status { case ok, unsupported, ineffective, error }

struct ToolResult {
    var status: Status
    var text: String
    var extra: [JSON] = []  // contenido MCP adicional (imágenes) en orden
    var prefix: [JSON] = []  // contenido previo al texto (batch con capturas intercaladas)

    static func ok(_ t: String) -> ToolResult { ToolResult(status: .ok, text: "ok " + t) }
    static func plain(_ t: String) -> ToolResult { ToolResult(status: .ok, text: t) }
    static func unsupported(_ t: String) -> ToolResult { ToolResult(status: .unsupported, text: "unsupported(\(t))") }
    static func ineffective(_ t: String) -> ToolResult { ToolResult(status: .ineffective, text: "ineffective(\(t))") }
    static func error(_ t: String) -> ToolResult { ToolResult(status: .error, text: "error: " + t) }

    var content: [JSON] { prefix + [["type": "text", "text": text]] + extra }
}

struct ToolError: Error {
    let result: ToolResult
    init(_ msg: String) { result = .error(msg) }
    init(unsupported msg: String) { result = .unsupported(msg) }
}

// MARK: - Config

struct Config {
    var allowedApps: [String] = []
    var maxElements = 80
    var axBudgetMs = 150.0
    var jpegQuality = 0.8
    var maxImageEdge = 1600.0

    /// Auto-ocultado del cursor fantasma por inactividad, en ms. 0 = nunca (permanece hasta `hide_cursor`).
    var phantomCursorIdleMs = 0

    /// Nunca se controlan, aunque estén en allowed_apps: contraseñas y ajustes de seguridad.
    static let hardDenied = [
        "com.apple.keychainaccess", "com.apple.passwords", "com.apple.systempreferences",
        "com.apple.securityagent", "com.1password", "com.agilebits", "com.bitwarden",
        "com.lastpass", "com.dashlane", "org.keepassxc",
    ]
}

final class ConfigStore {
    static let shared = ConfigStore()
    let path: String
    private var cached = Config()
    private var mtime: Date?

    private init() {
        if let env = ProcessInfo.processInfo.environment["COMPUTER_USE_CONFIG"], !env.isEmpty {
            path = (env as NSString).expandingTildeInPath
            return
        }
        // Busca config.json junto a Package.swift subiendo desde el binario.
        let exe = ProcessInfo.processInfo.environment["COMPUTER_USE_ORIGINAL"] ?? CommandLine.arguments[0]
        var dir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                path = dir.appendingPathComponent("config.json").path
                return
            }
            dir = dir.deletingLastPathComponent()
        }
        path = NSHomeDirectory() + "/computer-use-mcp/config.json"
    }

    /// Relee el archivo si cambió, para que editarlo no exija reiniciar el servidor.
    func load() -> Config {
        let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if m != nil, m == mtime { return cached }
        var c = Config()
        if let data = FileManager.default.contents(atPath: path),
            let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        {
            c.allowedApps = (j["allowed_apps"] as? [String]) ?? []
            if let v = j.int("max_elements") { c.maxElements = clamp(v, 5, 400) }
            if let v = j.num("ax_budget_ms") { c.axBudgetMs = clamp(v, 20, 2000) }
            if let v = j.num("jpeg_quality") { c.jpegQuality = clamp(v, 0.3, 1) }
            if let v = j.num("max_image_edge") { c.maxImageEdge = clamp(v, 400, 4000) }
            if let v = j.int("phantom_cursor_idle_ms") { c.phantomCursorIdleMs = clamp(v, 0, 3_600_000) }
        } else {
            log("no se pudo leer \(path); ninguna app está permitida")
        }
        cached = c
        mtime = m
        return c
    }

    /// nil si está permitida; si no, el motivo.
    func denial(name: String, bundleID: String?) -> String? {
        let bid = (bundleID ?? "").lowercased()
        if Config.hardDenied.contains(where: { bid.hasPrefix($0) }) {
            return "\"\(name)\" (\(bid)) handles passwords or security settings and is always blocked. Ask Marco to do this step by hand."
        }
        let allowed = load().allowedApps.map { $0.lowercased() }
        if allowed.contains(name.lowercased()) || (!bid.isEmpty && allowed.contains(bid)) { return nil }
        return "\"\(name)\"\(bid.isEmpty ? "" : " (\(bid))") is not in the allowed list. Only Marco can allow it by adding its name to \"allowed_apps\" in \(path). Do not look for another route."
    }
}

// MARK: - Permisos

enum Perm {
    static var axOK: Bool { AXIsProcessTrusted() }
    static var screenOK: Bool { CGPreflightScreenCaptureAccess() }
    static let noPrompt = ProcessInfo.processInfo.environment["COMPUTER_USE_NO_PROMPT"] == "1"
    private static var askedAX = false

    static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "?"
    }

    static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 ? pid_t(info.pbi_ppid) : 0
    }

    /// Proceso al que macOS atribuye los permisos TCC de este binario. Solo diagnóstico:
    /// `responsibility_get_pid_responsible_for_pid` no está en las cabeceras públicas, así que se
    /// busca con dlsym y, si no existe, se usa el ancestro más alto que viva dentro de un .app.
    static func responsible() -> (pid: pid_t, path: String) {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            let pid = unsafeBitCast(sym, to: Fn.self)(getpid())
            if pid > 0 { return (pid, path(of: pid)) }
        }
        var best = getpid()
        var cur = parent(of: getpid())
        while cur > 1 {
            if path(of: cur).contains(".app/") { best = cur }
            cur = parent(of: cur)
        }
        return (best, path(of: best))
    }

    /// Nombre de la app responsable (p. ej. «MiApp» para /Applications/MiApp.app/Contents/...); si no hay .app, la ruta del binario.
    static func responsibleName() -> String {
        let p = responsible().path
        if let r = p.range(of: ".app/") {
            return "«" + ((String(p[..<r.lowerBound]) as NSString).lastPathComponent) + "» (" + String(p[..<r.lowerBound]) + ".app)"
        }
        return "el binario " + p
    }

    /// Hace que la app aparezca en la lista de Accesibilidad (una sola vez por proceso). Marco la activa a mano.
    static func askAXOnce() {
        guard !askedAX, !noPrompt else { return }
        askedAX = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func axMessage() -> String {
        askAXOnce()
        return "Falta el permiso de Accesibilidad. Marco debe activarlo a mano en Configuración del Sistema → Privacidad y seguridad → Accesibilidad para \(responsibleName()). No intentes cambiarlo tú."
    }

    static func screenMessage() -> String {
        "Falta el permiso de Grabación de pantalla. Marco debe activarlo a mano en Configuración del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema para \(responsibleName()) y luego reiniciar esa app. No intentes cambiarlo tú."
    }

    static func doctor() -> String {
        let r = responsible()
        var chain: [String] = []
        var cur = getpid()
        while cur > 1, chain.count < 8 {
            chain.append("\(cur) \(path(of: cur))")
            cur = parent(of: cur)
        }
        return """
            Accesibilidad:        \(axOK ? "concedido" : "FALTA")
            Grabación de pantalla: \(screenOK ? "concedido" : "FALTA")
            Proceso responsable (a quien macOS atribuye los permisos): \(r.pid) \(r.path)
            Activar en Configuración del Sistema para: \(responsibleName())
            Config: \(ConfigStore.shared.path)
            Cadena de procesos:
              \(chain.joined(separator: "\n  "))
            """
    }
}
