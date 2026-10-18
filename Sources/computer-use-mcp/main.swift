import AppKit
import Foundation

// Servidor MCP por stdio: un mensaje JSON-RPC por línea.

let serverVersion = "0.1.1"

// ScreenCaptureKit exige la conexión con el servidor gráfico ya iniciada; si se le llama antes,
// las capturas se quedan sin respuesta.
_ = CGMainDisplayID()

/// replayd, el servicio de captura de macOS, identifica a cada cliente por la ruta del ejecutable:
/// dos instancias abiertas con la misma ruta (dos ventanas del cliente MCP, o una prueba con el
/// servidor ya cargado) se bloquean y las capturas no vuelven. Cada instancia se relanza desde una
/// copia propia en la carpeta temporal; el proceso y sus permisos son los mismos.
func reexecFromOwnPath() {
    let env = ProcessInfo.processInfo.environment
    guard env["COMPUTER_USE_ORIGINAL"] == nil else { return }
    let original = Perm.path(of: getpid())
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "computer-use-mcp"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
        if let pid = Int32(f.split(separator: "-").last ?? ""), kill(pid, 0) != 0 { try? fm.removeItem(atPath: dir + "/" + f) }
    }
    let target = dir + "/computer-use-mcp-\(getpid())"
    try? fm.removeItem(atPath: target)
    // Copia (en APFS es un clon, sin coste de disco) y no enlace duro: con el mismo inodo el sistema
    // sigue viendo la ruta original.
    if (try? fm.copyItem(atPath: original, toPath: target)) == nil { return }
    setenv("COMPUTER_USE_ORIGINAL", original, 1)
    var args: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    args[0] = strdup(target)
    args.append(nil)
    execv(target, args)
    unsetenv("COMPUTER_USE_ORIGINAL")  // si execv falla, se sigue desde la ruta original
}

if !CommandLine.arguments.contains("--doctor"), !CommandLine.arguments.contains("--version") {
    reexecFromOwnPath()
}

if CommandLine.arguments.contains("--doctor") {
    print(Perm.doctor())
    exit(0)
}
if CommandLine.arguments.contains("--version") {
    print(serverVersion)
    exit(0)
}

// MARK: - Esquemas de herramientas

private func prop(_ type: String, _ desc: String, items: String? = nil, values: [String]? = nil) -> JSON {
    var p: JSON = ["type": type, "description": desc]
    if let items { p["items"] = ["type": items] }
    if let values { p["enum"] = values }
    return p
}

private let appProp = prop("string", "App name, bundle id or pid. Must be in the allowed list (see list_apps).")
private let targeting: JSON = [
    "element_index": prop("integer", "Index [N] of an element from the last screenshot. Preferred."),
    "coordinate": prop("array", "[x, y] in the frame of the last screenshot (window points, origin top-left).", items: "number"),
    "target": prop("string", "\"focused\" = the element that has keyboard focus.", values: ["focused"]),
]
private let targetingNote = " Target with element_index, coordinate or target:\"focused\"; with none, the point of the previous action in that window is used."

private func tool(_ name: String, _ desc: String, _ props: JSON, required: [String] = ["app"], targeted: Bool = false) -> JSON {
    var p = props
    if required.contains("app") { p["app"] = appProp }
    if targeted { p.merge(targeting) { a, _ in a } }
    var schema: JSON = ["type": "object", "properties": p]
    if !required.isEmpty { schema["required"] = required }
    return ["name": name, "description": desc + (targeted ? targetingNote : ""), "inputSchema": schema]
}

private let batchActionProps: JSON = [
    "action": prop("string", "Tool to run.", values: ["click", "type", "key", "scroll", "drag", "menu", "screenshot", "zoom", "find", "open_app", "wait"]),
    "element_index": prop("integer", "Element [N] from the latest screenshot (including one taken earlier in this batch)."),
    "coordinate": prop("array", "[x, y] in frame coordinates.", items: "number"),
    "target": prop("string", "\"focused\"", values: ["focused"]),
    "text": prop("string", "Text for type."),
    "keys": prop("string", "Keys for key."),
    "direction": prop("string", "Direction for scroll.", values: ["up", "down", "left", "right"]),
    "amount": prop("number", "Ticks for scroll."),
    "to": prop("array", "End point [x, y] for drag.", items: "number"),
    "path": prop("array", "Menu path for menu.", items: "string"),
    "button": prop("string", "Mouse button for click.", values: ["left", "right", "middle"]),
    "count": prop("integer", "Click count."),
    "overwrite_existing": prop("boolean", "For type: replace the whole field."),
    "region": prop("array", "[x, y, width, height] for zoom.", items: "number"),
    "scale": prop("number", "Image scale for screenshot/zoom."),
    "ms": prop("integer", "Milliseconds for wait (max 3000)."),
]

let toolList: [JSON] = [
    tool("list_apps", "List running apps with name, bundle id, pid and whether each one is allowed.", [:], required: []),
    tool("list_windows", "List the windows of an app with their window_id, title and size.", [:]),
    tool("open_app", "Launch an app (or reopen its window) without bringing it to the front.", [:]),
    tool("hide_cursor", "Dismiss the floating agent cursor. It stays visible across the whole task; call this once when the task is finished so it does not linger on screen.", [:], required: []),
    tool(
        "screenshot",
        "Capture ONE window of an app (works even when it is covered by other windows) and list its actionable elements as numbered [N] lines with role, title and center position. Positions and all later coordinates are window points in the reported frame, whatever the image scale. Without window_id it captures the app's focused window.",
        [
            "window_id": prop("integer", "Window to capture (from list_windows). Later actions stay on this window."),
            "scale": prop("number", "0.1–1. Shrinks the image only; coordinates stay in the full frame."),
        ]),
    tool(
        "click",
        "Click an element or point without activating the app. Uses the accessibility action (press, focus, select) when there is one, otherwise a background mouse event.",
        [
            "button": prop("string", "Default left.", values: ["left", "right", "middle"]),
            "count": prop("integer", "1 (default), 2 for double click, 3 for triple."),
            "modifiers": prop("string", "Keys held during the click, e.g. \"cmd\" or \"shift+alt\"."),
        ], targeted: true),
    tool(
        "type",
        "Insert text into a text element at its caret (appends when the element was not focused). Never types into password fields. Use key for return/tab.",
        [
            "text": prop("string", "Text to insert."),
            "overwrite_existing": prop("boolean", "true = replace the whole content of the field. Default false."),
        ], required: ["app", "text"], targeted: true),
    tool(
        "key",
        "Press keys or shortcuts in the app, space-separated: \"return\", \"tab\", \"escape\", \"down down\", \"cmd+s\", \"cmd+shift+z\". Shortcuts with cmd are resolved to their menu item when one exists. Optional element_index/coordinate focuses that element first.",
        [
            "keys": prop("string", "Keys to press, in order."),
            "element_index": prop("integer", "Focus this element first."),
            "coordinate": prop("array", "Focus the element at [x, y] first.", items: "number"),
        ], required: ["app", "keys"]),
    tool(
        "scroll",
        "Scroll the scroll area under the target. Moves the scroll bar through accessibility when possible and reports the new position.",
        [
            "direction": prop("string", "Scroll direction.", values: ["up", "down", "left", "right"]),
            "amount": prop("number", "Ticks, default 3. One tick ≈ 15% of the visible area."),
        ], required: ["app", "direction"], targeted: true),
    tool(
        "drag",
        "Drag with the left button from the target to `to` (or to_element_index) using background mouse events. Only inside one window.",
        [
            "to": prop("array", "End point [x, y] in frame coordinates.", items: "number"),
            "to_element_index": prop("integer", "End element [N] from the last screenshot."),
            "modifiers": prop("string", "Keys held during the drag."),
        ], targeted: true),
    tool(
        "menu",
        "Run a menu-bar command by titles (case-insensitive, \"…\" ignored), e.g. path [\"File\", \"Save As\"], without opening the menu on screen. With list:true, or when the path ends in a submenu, it lists the children instead (omit path to list the menu bar).",
        [
            "path": prop("array", "Menu titles from the menu bar down to the item.", items: "string"),
            "list": prop("boolean", "true = list the children of `path` instead of pressing."),
        ]),
    tool(
        "zoom",
        "Return a crop of the window at full pixel density, to read small text. Read-only; it does not change coordinates.",
        [
            "region": prop("array", "[x, y, width, height] in frame coordinates.", items: "number"),
            "scale": prop("number", "0.1–1, default 1 (native density)."),
        ], required: ["app", "region"]),
    tool(
        "find",
        "Search the elements of the last screenshot (including ones not listed and plain texts) by role and/or title. Does not re-read the window.",
        [
            "role": prop("string", "Role as shown in the screenshot list: button, textfield, checkbox, row, link, popup, menuitem, text…"),
            "title_contains": prop("string", "Case-insensitive substring of the title or value."),
        ]),
    tool(
        "batch",
        "Run several actions in order in one call; stops at the first result that is not ok. {\"action\":\"screenshot\"} can go in between and at the end, and later element_index values refer to that newest screenshot. {\"action\":\"wait\",\"ms\":300} pauses.",
        [
            "actions": [
                "type": "array", "description": "Actions to run, each with \"action\" plus that tool's arguments.",
                "items": ["type": "object", "properties": batchActionProps, "required": ["action"]] as JSON,
            ] as JSON
        ], required: ["app", "actions"]),
]

let serverInstructions = """
    Controls macOS desktop apps in the background: the app is never brought to the front and the user's cursor does not move. \
    Loop: screenshot(app) → act with element_index (preferred) or coordinate → screenshot to verify. \
    Coordinates are always window points in the frame reported by the last screenshot, whatever the image scale. \
    Every action result starts with ok, unsupported(reason and what to use instead), ineffective(...) or error. \
    Use menu for menu-bar commands and batch to chain steps in one call. \
    A floating cursor follows your actions and stays visible for the whole task; call hide_cursor once when the task is finished. \
    Password fields and apps outside the allowed list are refused: ask the user instead of working around it.
    """

// MARK: - JSON-RPC

let tools = Tools()
let outLock = NSLock()

func send(_ obj: JSON) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    outLock.lock()
    FileHandle.standardOutput.write(data + Data([0x0A]))
    outLock.unlock()
}

func reply(_ id: Any, _ result: JSON) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as JSON])
}

func handle(_ line: String) {
    guard let data = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
        fail(NSNull(), -32700, "parse error")
        return
    }
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? JSON ?? [:]
    guard let id = msg["id"], !(id is NSNull) else { return }  // notificaciones: sin respuesta

    switch method {
    case "initialize":
        tools.prewarm()
        let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
        let asked = params["protocolVersion"] as? String ?? ""
        reply(
            id,
            [
                "protocolVersion": supported.contains(asked) ? asked : supported[0],
                "capabilities": ["tools": [:] as JSON] as JSON,
                "serverInfo": ["name": "computer-use", "version": serverVersion] as JSON,
                "instructions": serverInstructions,
            ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": toolList])
    case "tools/call":
        guard let name = params["name"] as? String else {
            fail(id, -32602, "missing tool name")
            return
        }
        let r = tools.call(name, params["arguments"] as? JSON ?? [:])
        reply(id, ["content": r.content, "isError": r.status == .error])
    case "resources/list":
        reply(id, ["resources": [] as [Any]])
    case "resources/templates/list":
        reply(id, ["resourceTemplates": [] as [Any]])
    case "prompts/list":
        reply(id, ["prompts": [] as [Any]])
    default:
        fail(id, -32601, "method not found: \(method)")
    }
}

private let startupOriginalPath = ProcessInfo.processInfo.environment["COMPUTER_USE_ORIGINAL"]
private let startupBinaryMtime: Date? = {
    guard let p = startupOriginalPath else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
}()

private func hotReloadIfBinaryChanged(pendingLine: String) {
    guard let orig = startupOriginalPath,
          let oldDate = startupBinaryMtime,
          let newDate = (try? FileManager.default.attributesOfItem(atPath: orig))?[.modificationDate] as? Date,
          newDate > oldDate else { return }
    setenv("COMPUTER_USE_PENDING_LINE", pendingLine, 1)
    unsetenv("COMPUTER_USE_ORIGINAL")
    var args: [UnsafeMutablePointer<CChar>?] = [strdup(orig), nil]
    execv(orig, &args)
}

// Las llamadas se atienden en serie fuera del hilo principal; el principal solo mantiene
// el run loop que AppKit necesita para tener al día la lista de apps.
let worker = DispatchQueue(label: "computer-use.worker", qos: .userInitiated)
PhantomCursor.shared.setupOnMainThread()
tools.prewarm()
if let pending = ProcessInfo.processInfo.environment["COMPUTER_USE_PENDING_LINE"], !pending.isEmpty {
    unsetenv("COMPUTER_USE_PENDING_LINE")
    worker.async { handle(pending) }
}
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        worker.async {
            hotReloadIfBinaryChanged(pendingLine: trimmed)
            handle(trimmed)
        }
    }
    worker.async { exit(0) }
}
RunLoop.main.run()
