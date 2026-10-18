import AppKit
import ApplicationServices
import Foundation

// MARK: - Lectura básica

func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axStr(_ el: AXUIElement, _ name: String) -> String? { axAttr(el, name) as? String }

func axElement(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = axAttr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func asElements(_ v: AnyObject?) -> [AXUIElement] {
    guard let v, CFGetTypeID(v) == CFArrayGetTypeID(), let a = v as? [AnyObject] else { return [] }
    return a.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
}

func axChildren(_ el: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    asElements(axAttr(el, name))
}

func asPoint(_ v: AnyObject?) -> CGPoint? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

func asSize(_ v: AnyObject?) -> CGSize? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

func asRange(_ v: AnyObject?) -> CFRange? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CFRange()
    return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = asPoint(axAttr(el, kAXPositionAttribute)), let s = asSize(axAttr(el, kAXSizeAttribute)) else { return nil }
    return CGRect(origin: p, size: s)
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    return AXUIElementCopyActionNames(el, &names) == .success ? (names as? [String] ?? []) : []
}

func axSettable(_ el: AXUIElement, _ name: String) -> Bool {
    var b: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(el, name as CFString, &b) == .success && b.boolValue
}

@discardableResult
func axSet(_ el: AXUIElement, _ name: String, _ value: AnyObject) -> AXError {
    AXUIElementSetAttributeValue(el, name as CFString, value)
}

func axSetRange(_ el: AXUIElement, _ location: Int, _ length: Int) -> AXError {
    var r = CFRange(location: location, length: length)
    guard let v = AXValueCreate(.cfRange, &r) else { return .failure }
    return axSet(el, kAXSelectedTextRangeAttribute, v)
}

enum PerformOutcome { case done, pending, failed(AXError) }

/// AXPress sobre algo que abre un menú o un diálogo modal no vuelve hasta que se cierra;
/// se lanza aparte y, pasado el plazo, se da por aceptado.
func axPerform(_ el: AXUIElement, _ action: String, timeout: Double = 0.35) -> PerformOutcome {
    let sem = DispatchSemaphore(value: 0)
    var err = AXError.cannotComplete
    DispatchQueue.global(qos: .userInitiated).async {
        err = AXUIElementPerformAction(el, action as CFString)
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut { return .pending }
    return err == .success ? .done : .failed(err)
}

// MARK: - Descripción de un elemento

let shortRoles: [String: String] = [
    "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
    "AXMenuButton": "menubutton", "AXTextField": "textfield", "AXTextArea": "textarea", "AXComboBox": "combobox",
    "AXSlider": "slider", "AXLink": "link", "AXIncrementor": "stepper", "AXDisclosureTriangle": "disclosure",
    "AXMenuItem": "menuitem", "AXColorWell": "colorwell", "AXRow": "row", "AXStaticText": "text",
    "AXHeading": "heading", "AXDateField": "datefield", "AXTimeField": "timefield",
]

let shortSubroles: [String: String] = [
    "AXSecureTextField": "securefield", "AXSearchField": "searchfield", "AXTabButton": "tab",
    "AXCloseButton": "button", "AXSwitch": "switch", "AXToggle": "toggle", "AXOutlineRow": "row",
]

let actionableRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
    "AXComboBox", "AXSlider", "AXLink", "AXIncrementor", "AXDisclosureTriangle", "AXMenuItem", "AXColorWell",
    "AXRow", "AXDateField", "AXTimeField",
]

let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
let pressRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXMenuItem",
    "AXDisclosureTriangle", "AXIncrementor",
]

struct Node {
    let el: AXUIElement
    let role: String
    let subrole: String
    var label: String
    var value: String?
    var frame: CGRect  // puntos de pantalla, recortado a lo visible
    let enabled: Bool
    let focused: Bool
    let parent: Int
    let actionable: Bool

    var kind: String { shortSubroles[subrole] ?? shortRoles[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased() }
    var isSecure: Bool { subrole == "AXSecureTextField" }
}

func displayValue(_ v: AnyObject?, role: String) -> String? {
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber {
        if role == "AXCheckBox" || role == "AXRadioButton" { return n.intValue != 0 ? "on" : "off" }
        if role == "AXSlider" || role == "AXIncrementor" { return n.stringValue }
    }
    return nil
}

/// Rol, subrol, etiqueta y estado de un elemento suelto (para objetivos por coordenada o foco).
func describe(_ el: AXUIElement) -> Node {
    let role = axStr(el, kAXRoleAttribute) ?? "AXUnknown"
    let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { axStr(el, $0) }.first { !$0.isEmpty } ?? ""
    return Node(
        el: el, role: role, subrole: axStr(el, kAXSubroleAttribute) ?? "", label: label,
        value: displayValue(axAttr(el, kAXValueAttribute), role: role), frame: axFrame(el) ?? .null,
        enabled: (axAttr(el, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true,
        focused: (axAttr(el, kAXFocusedAttribute) as? NSNumber)?.boolValue ?? false,
        parent: -1, actionable: actionableRoles.contains(role))
}

func nodeTitle(_ n: Node) -> String {
    var s = n.kind
    if !n.label.isEmpty { s += " \"\(truncate(n.label, 40))\"" }
    return s
}

// MARK: - Recorrido del árbol con presupuesto

struct Walk {
    var actionable: [Node] = []
    var texts: [Node] = []
    var visited = 0
    var truncated = false
    var ms = 0.0
}

private let walkAttrs =
    [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXChildrenAttribute,
    ] as CFArray

/// Recorrido en anchura desde la ventana: una llamada IPC por elemento, poda de lo que no se ve
/// y corte por tiempo. Devuelve los accionables en orden de lectura.
func walkWindow(_ window: AXUIElement, frame winFrame: CGRect, budgetMs: Double, hardCap: Int = 700) -> Walk {
    let t0 = nowMs()
    var out = Walk()
    var all: [Node] = []
    var queue: [(el: AXUIElement, parent: Int, clip: CGRect, depth: Int)] = [(window, -1, winFrame, 0)]
    var head = 0

    while head < queue.count {
        if nowMs() - t0 > budgetMs || all.count >= hardCap {
            out.truncated = true
            break
        }
        let item = queue[head]
        head += 1

        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item.el, walkAttrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
            let v = raw as? [AnyObject], v.count == 10
        else { continue }
        out.visited += 1

        let role = v[0] as? String ?? "AXUnknown"
        let subrole = v[1] as? String ?? ""
        let inMenu = role == "AXMenu" || role == "AXMenuItem"
        var frame = CGRect.null
        if let p = asPoint(v[5]), let s = asSize(v[6]) { frame = CGRect(origin: p, size: s) }
        let hasArea = !frame.isNull && frame.width > 1 && frame.height > 1
        // Fuera de lo visible: ni el elemento ni sus hijos. Los menús abiertos pueden salirse de la ventana.
        if hasArea, !inMenu, !frame.intersects(item.clip) { continue }
        let visible = hasArea ? (inMenu ? frame : frame.intersection(item.clip)) : CGRect.null

        let title = (v[2] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (v[3] as? String ?? "")
        let isText = role == "AXStaticText" || role == "AXHeading"
        let actionable = actionableRoles.contains(role) && hasArea
        let node = Node(
            el: item.el, role: role, subrole: subrole, label: title, value: displayValue(v[4], role: role),
            frame: visible, enabled: (v[7] as? NSNumber)?.boolValue ?? true,
            focused: (v[8] as? NSNumber)?.boolValue ?? false, parent: item.parent, actionable: actionable)
        let idx = all.count
        all.append(node)

        // Un texto dentro de una fila, botón o enlace sin título le sirve de etiqueta.
        if isText, let text = node.value ?? (title.isEmpty ? nil : title) {
            var p = item.parent
            var hops = 0
            while p >= 0, hops < 5 {
                if all[p].actionable {
                    if all[p].label.isEmpty { all[p].label = text }
                    break
                }
                p = all[p].parent
                hops += 1
            }
        }

        if item.depth >= 40 || role == "AXScrollBar" || role == "AXTextArea" || role == "AXMenuBar" { continue }
        // Hojas con título: no hace falta bajar.
        if actionable, !title.isEmpty, role != "AXPopUpButton", role != "AXMenuButton", role != "AXRow", role != "AXMenuItem" { continue }

        var kids = asElements(v[9])
        if role == "AXTable" || role == "AXOutline" {
            let rows = axChildren(item.el, kAXVisibleRowsAttribute)
            if !rows.isEmpty { kids = rows + [axElement(item.el, kAXHeaderAttribute)].compactMap { $0 } }
        } else if role == "AXList", kids.count > 60 {
            let vis = axChildren(item.el, kAXVisibleChildrenAttribute)
            if !vis.isEmpty { kids = vis }
        }
        let clip = (role == "AXScrollArea" && hasArea) ? item.clip.intersection(frame) : item.clip
        for k in kids.prefix(300) { queue.append((k, idx, clip, item.depth + 1)) }
    }

    var seenKeys = Set<String>()
    for n in all where !n.frame.isNull {
        if n.actionable {
            if !n.label.isEmpty {
                let key = "\(n.role)|\(n.label)|\(Int(n.frame.midX.rounded()))|\(Int(n.frame.midY.rounded()))"
                if !seenKeys.insert(key).inserted { continue }
            }
            out.actionable.append(n)
        } else if n.role == "AXStaticText" || n.role == "AXHeading", n.value != nil || !n.label.isEmpty {
            out.texts.append(n)
        }
    }
    // Orden de lectura: primero ítems de menús/popovers abiertos (AXMenuItem), luego por filas de ~10 pt y de izquierda a derecha.
    out.actionable.sort {
        let ma = $0.role == "AXMenuItem" ? 0 : 1
        let mb = $1.role == "AXMenuItem" ? 0 : 1
        if ma != mb { return ma < mb }
        let (ya, yb) = (Int($0.frame.minY / 10), Int($1.frame.minY / 10))
        return ya != yb ? ya < yb : $0.frame.minX < $1.frame.minX
    }
    out.ms = nowMs() - t0
    return out
}

// MARK: - Menús

func normTitle(_ s: String) -> String {
    s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        .trimmingCharacters(in: .whitespaces).lowercased()
}

struct MenuEntry {
    let el: AXUIElement
    let title: String
    let enabled: Bool
    let mark: String
    let cmdChar: String
    let cmdMods: Int
    let hasSubmenu: Bool
}

private let menuAttrs =
    [
        kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute,
    ] as CFArray

/// Hijos de una barra de menús, un ítem de barra o un ítem con submenú (salta el AXMenu intermedio).
func menuEntries(_ container: AXUIElement) -> [MenuEntry] {
    var kids = axChildren(container)
    if kids.count == 1, axStr(kids[0], kAXRoleAttribute) == "AXMenu" { kids = axChildren(kids[0]) }
    return kids.compactMap { k in
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(k, menuAttrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
            let v = raw as? [AnyObject], v.count == 6, let title = v[0] as? String, !title.isEmpty
        else { return nil }
        return MenuEntry(
            el: k, title: title, enabled: (v[1] as? NSNumber)?.boolValue ?? true, mark: v[2] as? String ?? "",
            cmdChar: v[3] as? String ?? "", cmdMods: (v[4] as? NSNumber)?.intValue ?? 0,
            hasSubmenu: !asElements(v[5]).isEmpty)
    }
}

/// AXMenuItemCmdModifiers: 0 = solo cmd; 1 shift, 2 option, 4 control, 8 = sin cmd.
func shortcutText(_ e: MenuEntry) -> String {
    guard !e.cmdChar.isEmpty else { return "" }
    var s = ""
    if e.cmdMods & 4 != 0 { s += "ctrl+" }
    if e.cmdMods & 2 != 0 { s += "alt+" }
    if e.cmdMods & 1 != 0 { s += "shift+" }
    if e.cmdMods & 8 == 0 { s += "cmd+" }
    return s + e.cmdChar.lowercased()
}

/// Busca un ítem de menú por título normalizado, con soporte para ítems dinámicos
/// de Undo/Redo (p. ej. "Undo" -> "Undo Typing", "Deshacer" -> "Deshacer escritura"),
/// igual que `MFr` en `appscoped-impl.js` de Claude Desktop.
func matchMenuEntry(_ entries: [MenuEntry], target: String) -> MenuEntry? {
    let want = normTitle(target)
    if let exact = entries.first(where: { normTitle($0.title) == want }) {
        return exact
    }
    let dynamicPrefixes: Set<String> = ["undo", "redo", "deshacer", "rehacer"]
    if dynamicPrefixes.contains(want) {
        let prefix = want + " "
        let matches = entries.filter { normTitle($0.title).hasPrefix(prefix) }
        if matches.count == 1 { return matches[0] }
    }
    return nil
}

// MARK: - Operaciones AX parametrizadas de texto (inspiradas en computer_use.node de Claude)

func axParamAttr(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &v) == .success ? v : nil
}

/// Usa `kAXRangeForPositionParameterizedAttribute` (`AXRangeForPosition`) para obtener el índice
/// de carácter bajo un punto de pantalla `(x, y)` dentro de un `AXTextField` o `AXTextArea`.
func axCharIndexAtPoint(_ el: AXUIElement, _ pt: CGPoint) -> Int? {
    var p = pt
    guard let ptVal = AXValueCreate(.cgPoint, &p),
          let rangeVal = axParamAttr(el, kAXRangeForPositionParameterizedAttribute as String, ptVal),
          let range = asRange(rangeVal)
    else { return nil }
    return max(0, range.location)
}

/// Posiciona el cursor (`count == 1`), selecciona una palabra (`count == 2`) o selecciona
/// una línea/párrafo (`count == 3`) en un control de texto en background puramente vía AX.
func clickTextElementViaAX(_ el: AXUIElement, at pt: CGPoint, count: Int) -> Bool {
    guard axSettable(el, kAXSelectedTextRangeAttribute) else { return false }
    if axSettable(el, kAXFocusedAttribute) {
        axSet(el, kAXFocusedAttribute, kCFBooleanTrue)
    }
    guard let idx = axCharIndexAtPoint(el, pt) else {
        // Si AXRangeForPosition no está disponible pero el elemento permite foco, al menos enfócalo
        return false
    }
    let text = (axAttr(el, kAXValueAttribute) as? String) ?? ""
    let utf16 = Array(text.utf16)
    let clamped = min(max(0, idx), utf16.count)

    if count <= 1 {
        return axSetRange(el, clamped, 0) == .success
    } else if count == 2 {
        // Selección de palabra alrededor de `clamped`
        let isWordChar: (UInt16) -> Bool = { u in
            guard let scalar = UnicodeScalar(u) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || u == 0x5F // '_'
        }
        var start = clamped
        while start > 0 && isWordChar(utf16[start - 1]) { start -= 1 }
        var end = clamped
        while end < utf16.count && isWordChar(utf16[end]) { end += 1 }
        return axSetRange(el, start, max(0, end - start)) == .success
    } else {
        // Selección de línea/párrafo alrededor de `clamped` (`count >= 3`)
        var start = clamped
        while start > 0 && utf16[start - 1] != 0x0A && utf16[start - 1] != 0x0D { start -= 1 }
        var end = clamped
        while end < utf16.count && utf16[end] != 0x0A && utf16[end] != 0x0D { end += 1 }
        if end < utf16.count && utf16[end] == 0x0A { end += 1 }
        return axSetRange(el, start, max(0, end - start)) == .success
    }
}

/// Resuelve el elemento de texto objetivo dentro de una app/ventana en background.
/// En background, `kAXFocusedUIElementAttribute` de la aplicación suele ser `nil` o apuntar
/// a `AXWindow` porque la ventana no tiene key focus del sistema. En ese caso, busca dentro
/// de la ventana el control de texto enfocado o el `AXTextArea`/`AXTextField` editable principal.
func findTargetTextElement(appAX: AXUIElement, winAX: AXUIElement?) -> AXUIElement? {
    if let foc = axElement(appAX, kAXFocusedUIElementAttribute) {
        let role = axStr(foc, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) || axSettable(foc, kAXValueAttribute) || axSettable(foc, kAXSelectedTextAttribute) {
            return foc
        }
    }
    guard let win = winAX else { return nil }
    if let winFoc = axElement(win, kAXFocusedUIElementAttribute) {
        let role = axStr(winFoc, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) || axSettable(winFoc, kAXValueAttribute) || axSettable(winFoc, kAXSelectedTextAttribute) {
            return winFoc
        }
    }
    // Búsqueda rápida en anchura dentro de la ventana para localizar el área/campo de texto editable
    var queue: [AXUIElement] = [win]
    var head = 0
    var candidates: [AXUIElement] = []
    let t0 = nowMs()
    while head < queue.count && head < 250 && (nowMs() - t0) < 60 {
        let cur = queue[head]
        head += 1
        let role = axStr(cur, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) {
            let focused = (axAttr(cur, kAXFocusedAttribute) as? NSNumber)?.boolValue ?? false
            if focused { return cur }
            if axSettable(cur, kAXValueAttribute) || axSettable(cur, kAXSelectedTextRangeAttribute) {
                candidates.append(cur)
            }
        }
        if role != "AXMenuBar" && role != "AXScrollBar" && role != "AXTextArea" {
            for child in axChildren(cur).prefix(80) {
                queue.append(child)
            }
        }
    }
    // Preferimos AXTextArea editable (p. ej. documento de TextEdit/Notes) o único AXTextField
    if let area = candidates.first(where: { axStr($0, kAXRoleAttribute) == "AXTextArea" }) {
        return area
    }
    return candidates.count == 1 ? candidates[0] : candidates.first
}

/// Selecciona todo el texto (`cmd+a`) en un elemento de texto vía `kAXSelectedTextRangeAttribute`.
func axSelectAllText(_ el: AXUIElement) -> Bool {
    guard axSettable(el, kAXSelectedTextRangeAttribute) else { return false }
    let count: Int
    if let n = (axAttr(el, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue {
        count = n
    } else if let s = axAttr(el, kAXValueAttribute) as? String {
        count = s.utf16.count
    } else {
        return false
    }
    return axSetRange(el, 0, max(0, count)) == .success
}

/// Borra la selección actual o 1 carácter hacia atrás (`forward = false`, Backspace)
/// o hacia adelante (`forward = true`, Forward Delete) puramente vía AX.
func axDeleteText(_ el: AXUIElement, forward: Bool) -> Bool {
    if axSettable(el, kAXSelectedTextAttribute),
       let curRange = asRange(axAttr(el, kAXSelectedTextRangeAttribute)) {
        if curRange.length > 0 {
            return axSet(el, kAXSelectedTextAttribute, "" as CFString) == .success
        }
        let totalLen = (axAttr(el, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            ?? (axAttr(el, kAXValueAttribute) as? String)?.utf16.count ?? 0
        if !forward {
            guard curRange.location > 0 else { return true }
            guard axSetRange(el, curRange.location - 1, 1) == .success else { return false }
            return axSet(el, kAXSelectedTextAttribute, "" as CFString) == .success
        } else {
            guard curRange.location < totalLen else { return true }
            guard axSetRange(el, curRange.location, 1) == .success else { return false }
            return axSet(el, kAXSelectedTextAttribute, "" as CFString) == .success
        }
    }
    return false
}

