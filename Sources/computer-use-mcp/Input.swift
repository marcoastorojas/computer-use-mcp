import CoreGraphics
import Foundation

// Eventos sintéticos dirigidos a un pid: no mueven el cursor real ni activan la app.
// Solo se usan cuando no hay una acción de accesibilidad equivalente.

private let source = CGEventSource(stateID: .hidSystemState)

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111,
]

let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "shift": .maskShift,
    "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
]

struct KeyCombo {
    var flags: CGEventFlags = []
    var code: CGKeyCode?
    var char: String = ""  // tecla tal como se pidió, en minúsculas
}

/// "cmd+shift+s", "Return", "ctrl+a"… nil si no se reconoce.
func parseCombo(_ s: String) -> KeyCombo? {
    var combo = KeyCombo()
    let parts = s == "+" ? ["+"] : s.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init)
    guard !parts.isEmpty else { return nil }
    for (i, p) in parts.enumerated() {
        if i < parts.count - 1 {
            guard let f = modifierFlags[p] else { return nil }
            combo.flags.insert(f)
        } else {
            combo.char = p
            combo.code = keyCodes[p]
            if combo.code == nil, p.count != 1 { return nil }
        }
    }
    return combo
}

func parseModifiers(_ v: Any?) -> CGEventFlags? {
    var names: [String] = []
    if let s = v as? String { names = s.lowercased().split(whereSeparator: { "+, ".contains($0) }).map(String.init) }
    if let a = v as? [String] { names = a.map { $0.lowercased() } }
    var flags: CGEventFlags = []
    for n in names {
        guard let f = modifierFlags[n] else { return nil }
        flags.insert(f)
    }
    return flags
}

func postKey(pid: pid_t, combo: KeyCombo) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: combo.code ?? 0, keyDown: down) else { continue }
        e.flags = combo.flags
        if combo.code == nil {
            let u = Array(combo.char.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        SkyLight.postEvent(e, toPid: pid)
        usleep(8000)
    }
}

/// Escribe texto como pulsaciones Unicode; salto de línea y tabulador van como teclas reales.
func postText(pid: pid_t, _ text: String) {
    var chunk: [UniChar] = []
    func flush() {
        guard !chunk.isEmpty else { return }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            SkyLight.postEvent(e, toPid: pid)
            usleep(3000)
        }
        chunk.removeAll()
    }
    for ch in text {
        if ch == "\n" || ch == "\t" {
            flush()
            postKey(pid: pid, combo: KeyCombo(code: ch == "\n" ? 36 : 48))
            continue
        }
        let units = Array(String(ch).utf16)
        if chunk.count + units.count > 16 { flush() }
        chunk += units
    }
    flush()
}

private func mouse(
    _ pid: pid_t,
    _ type: CGEventType,
    _ p: CGPoint,
    _ button: CGMouseButton,
    clicks: Int64,
    flags: CGEventFlags,
    window: CGWindowID,
    windowBounds: CGRect?,
    deltaX: Int64 = 0,
    deltaY: Int64 = 0
) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    e.flags = flags
    if deltaX != 0 || deltaY != 0 {
        e.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
        e.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
    }
    SkyLight.stampWindowEvent(
        e,
        pid: pid,
        windowID: window,
        screenPoint: p,
        windowBounds: windowBounds,
        button: button,
        clickCount: clicks
    )
    SkyLight.postEvent(e, toPid: pid)
}

func postClick(
    pid: pid_t,
    at p: CGPoint,
    button: String,
    count: Int,
    flags: CGEventFlags,
    window: CGWindowID,
    windowBounds: CGRect? = nil
) {
    let (btn, down, up): (CGMouseButton, CGEventType, CGEventType) =
        button == "right"
        ? (.right, .rightMouseDown, .rightMouseUp)
        : button == "middle" ? (.center, .otherMouseDown, .otherMouseUp) : (.left, .leftMouseDown, .leftMouseUp)
    mouse(pid, .mouseMoved, p, btn, clicks: 0, flags: flags, window: window, windowBounds: windowBounds)
    usleep(10000)
    for i in 1...max(count, 1) {
        mouse(pid, down, p, btn, clicks: Int64(i), flags: flags, window: window, windowBounds: windowBounds)
        usleep(25000)
        mouse(pid, up, p, btn, clicks: Int64(i), flags: flags, window: window, windowBounds: windowBounds)
        usleep(25000)
    }
}

func postDrag(
    pid: pid_t,
    from a: CGPoint,
    to b: CGPoint,
    flags: CGEventFlags,
    window: CGWindowID,
    windowBounds: CGRect? = nil
) {
    mouse(pid, .mouseMoved, a, .left, clicks: 0, flags: flags, window: window, windowBounds: windowBounds)
    usleep(10000)
    mouse(pid, .leftMouseDown, a, .left, clicks: 1, flags: flags, window: window, windowBounds: windowBounds)
    usleep(40000)
    let steps = 12
    var prevX = a.x.rounded()
    var prevY = a.y.rounded()
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let cur = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        let curX = cur.x.rounded()
        let curY = cur.y.rounded()
        let dx = Int64(curX - prevX)
        let dy = Int64(curY - prevY)
        prevX = curX
        prevY = curY
        mouse(
            pid, .leftMouseDragged, cur, .left, clicks: 1, flags: flags,
            window: window, windowBounds: windowBounds, deltaX: dx, deltaY: dy
        )
        usleep(12000)
    }
    usleep(30000)
    mouse(pid, .leftMouseUp, b, .left, clicks: 1, flags: flags, window: window, windowBounds: windowBounds)
}

func postScroll(
    pid: pid_t,
    at p: CGPoint,
    dx: Int32,
    dy: Int32,
    window: CGWindowID = 0,
    windowBounds: CGRect? = nil
) {
    guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    e.location = p
    SkyLight.stampWindowEvent(
        e,
        pid: pid,
        windowID: window,
        screenPoint: p,
        windowBounds: windowBounds,
        button: .left,
        clickCount: 0,
        eventNumber: 0
    )
    SkyLight.postEvent(e, toPid: pid)
}

