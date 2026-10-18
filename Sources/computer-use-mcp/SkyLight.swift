import ApplicationServices
import Cocoa
import Darwin
import Foundation

// MARK: - Private SkyLight & HIServices Bridge (Claude app-cu-helper equivalent)
//
// Provee acceso dinámico (vía dlsym) a los símbolos privados de SkyLight y
// ApplicationServices que usa `app-cu-helper` y `computer_use.node` en Claude Desktop:
// 1. `_AXUIElementGetWindow`: mapeo exacto AXUIElement -> CGWindowID.
// 2. `CGEventSetWindowLocation` + `SLEventSetIntegerValueField` (f40, f51, f91, f92)
//    + `SLSEventAuthenticationMessage` + `SLEventPostToPid`: entrega de eventos de
//    ratón/teclado a ventanas en background con coordenadas locales y sobre de
//    autenticación de WindowServer.
// 3. `GetProcessForPID` + `SLPSPostEventRecordTo`: `keyWindowSpoof` y
//    `wakeChromiumCompositor` sin robar el foco ni elevar la ventana sobre la app
//    activa del usuario.

enum SkyLight {

    struct ProcessSerialNumber {
        var highLongOfPSN: UInt32 = 0
        var lowLongOfPSN: UInt32 = 0
    }

    private typealias AXUIElementGetWindowFn = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private typealias CGEventSetWindowLocationFn = @convention(c) (
        CGEvent, CGPoint
    ) -> Void

    private typealias SLEventSetIntegerValueFieldFn = @convention(c) (
        CGEvent, UInt32, Int64
    ) -> Void

    private typealias SLEventPostToPidFn = @convention(c) (
        pid_t, CGEvent
    ) -> Int32

    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutableRawPointer
    ) -> OSStatus

    private typealias SLPSGetFrontProcessFn = @convention(c) (
        UnsafeMutableRawPointer
    ) -> Int32

    private typealias SLPSPostEventRecordToFn = @convention(c) (
        UnsafeMutableRawPointer, UnsafeRawPointer
    ) -> Int32

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static let skyLightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)
    }()

    private static func sym<T>(_ name: String) -> T? {
        if let h = skyLightHandle, let p = dlsym(h, name) {
            return unsafeBitCast(p, to: T.self)
        }
        if let p = dlsym(rtldDefault, name) {
            return unsafeBitCast(p, to: T.self)
        }
        return nil
    }

    private static let fnAXGetWindow: AXUIElementGetWindowFn? = sym("_AXUIElementGetWindow")
    private static let fnSetWindowLocation: CGEventSetWindowLocationFn? = sym("CGEventSetWindowLocation")
    private static let fnSetIntField: SLEventSetIntegerValueFieldFn? = sym("SLEventSetIntegerValueField")
    private static let fnPostToPid: SLEventPostToPidFn? = sym("SLEventPostToPid")
    private static let fnGetProcessForPID: GetProcessForPIDFn? = sym("GetProcessForPID")
    private static let fnGetFrontProcess: SLPSGetFrontProcessFn? = sym("_SLPSGetFrontProcess")
    private static let fnPostEventRecordTo: SLPSPostEventRecordToFn? = sym("SLPSPostEventRecordTo")

    private static var mouseEventCounter: Int64 = 1
    private static let counterLock = NSLock()

    private static func nextMouseEventNumber() -> Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        let current = mouseEventCounter
        mouseEventCounter &+= 1
        return current
    }

    // MARK: - 1. Exact AXUIElement -> CGWindowID

    /// Obtiene el `CGWindowID` exacto de un `AXUIElement` usando `_AXUIElementGetWindow`.
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let fn = fnAXGetWindow else { return nil }
        var wid: CGWindowID = 0
        let err = fn(element, &wid)
        return (err == .success && wid != 0) ? wid : nil
    }

    // MARK: - 2. Background Mouse/Scroll Event Stamping & Posting

    /// Estampa los campos de WindowServer que AppKit y Chromium esperan en eventos
    /// dirigidos a una ventana en background (equivalente a `0x10003744c` en `app-cu-helper`).
    ///
    /// Campos estampados:
    /// - `0` (`mouseEventNumber`): contador incremental
    /// - `1` (`mouseEventClickState`): `clickCount`
    /// - `3` (`mouseEventButtonNumber`): `button.rawValue`
    /// - `7` (`mouseEventSubtype`): `3` (window-targeted subtype)
    /// - `40` (`0x28`, `f40`): `pid` del proceso destino
    /// - `51` (`0x33`, `f51` / `mouseEventWindowUnderMousePointer`): `windowID`
    /// - `91` (`0x5b` / `mouseEventWindowUnderMousePointerThatCanHandleThisEvent`): `windowID`
    /// - `92` (`0x5c`): `windowID`
    /// - `CGEventSetWindowLocation`: coordenadas relativas al origen de la ventana.
    static func stampWindowEvent(
        _ event: CGEvent,
        pid: pid_t,
        windowID: CGWindowID,
        screenPoint: CGPoint,
        windowBounds: CGRect?,
        button: CGMouseButton = .left,
        clickCount: Int64 = 1,
        eventNumber: Int64? = nil
    ) {
        let evNum = eventNumber ?? nextMouseEventNumber()
        let setField: (UInt32, Int64) -> Void = { field, val in
            if let fn = fnSetIntField {
                fn(event, field, val)
            } else if let cgField = CGEventField(rawValue: field) {
                event.setIntegerValueField(cgField, value: val)
            }
        }

        setField(0, evNum)
        setField(1, clickCount)
        setField(3, Int64(button.rawValue))
        setField(7, 3)
        setField(40, Int64(pid))
        if windowID != 0 {
            let wid64 = Int64(windowID)
            setField(51, wid64)
            setField(91, wid64)
            setField(92, wid64)
        }

        if let bounds = windowBounds, let setWinLoc = fnSetWindowLocation {
            let winLocal = CGPoint(
                x: screenPoint.x - bounds.origin.x,
                y: screenPoint.y - bounds.origin.y
            )
            setWinLoc(event, winLocal)
        }
    }

    /// Envía un `CGEvent` a un PID usando `SLEventPostToPid` (o `CGEventPostToPid` como fallback).
    static func postEvent(_ event: CGEvent, toPid pid: pid_t) {
        // Estampa f40 = pid también en eventos de teclado
        if let fn = fnSetIntField {
            fn(event, 40, Int64(pid))
        }
        if let post = fnPostToPid {
            _ = post(pid, event)
        } else {
            event.postToPid(pid)
        }
    }

    // MARK: - 3. Key-Window Spoofing & Chromium Compositor Wake (`SLPSPostEventRecordTo`)

    /// Comprueba si el proceso `pid` NO es el proceso frontal del usuario.
    private static func isBackgroundProcess(_ pid: pid_t) -> (isBackground: Bool, psn: ProcessSerialNumber) {
        var targetPSN = ProcessSerialNumber()
        guard let getPSN = fnGetProcessForPID,
              getPSN(pid, &targetPSN) == noErr else {
            return (false, targetPSN)
        }
        if let getFront = fnGetFrontProcess {
            var frontPSN = ProcessSerialNumber()
            if getFront(&frontPSN) == 0,
               frontPSN.highLongOfPSN == targetPSN.highLongOfPSN,
               frontPSN.lowLongOfPSN == targetPSN.lowLongOfPSN {
                return (false, targetPSN)
            }
        }
        return (true, targetPSN)
    }

    /// Construye un registro de evento SkyLight de 248 bytes (`0xf8`) idéntico al de `app-cu-helper`.
    private static func makeKeyWindowRecord(windowID: CGWindowID, phaseByte: UInt8) -> [UInt8] {
        var rec = [UInt8](repeating: 0, count: 0xf8)
        rec[4] = 0xf8
        rec[8] = 0x0d  // kCGSEventKeyWindow
        var wid = windowID.littleEndian
        withUnsafeBytes(of: &wid) { bytes in
            for i in 0..<4 { rec[0x3c + i] = bytes[i] }
        }
        rec[0x8a] = phaseByte  // 1 = becomeKey, 2 = resignKey
        return rec
    }

    private static func makeAppActivationRecord(windowID: CGWindowID, eventType: UInt8) -> [UInt8] {
        var rec = [UInt8](repeating: 0, count: 0xf8)
        rec[4] = 0xf8
        rec[8] = eventType  // 1 = appActivated, 2 = appDeactivated
        var magic: UInt64 = 0xc0f8_6a00_0000_0000
        withUnsafeBytes(of: &magic) { bytes in
            for i in 0..<8 {
                rec[0x20 + i] = bytes[i]
                rec[0x28 + i] = bytes[i]
            }
        }
        var flags: UInt32 = 0x0010_0000
        withUnsafeBytes(of: &flags) { bytes in
            for i in 0..<4 { rec[0x38 + i] = bytes[i] }
        }
        var wid = windowID.littleEndian
        withUnsafeBytes(of: &wid) { bytes in
            for i in 0..<4 { rec[0x3c + i] = bytes[i] }
        }
        return rec
    }

    /// Despierta el compositor de una ventana en background y hace que su ventana
    /// sea Key Window internamente sin elevarla ni cambiar la app activa del usuario.
    /// Equivalente a `0x10002179c` (`keyWindowSpoof(begin)` / `wakeChromiumCompositor`) en `app-cu-helper`.
    @discardableResult
    static func beginKeyWindowSpoof(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0, let postRec = fnPostEventRecordTo else { return false }
        var (isBg, psn) = isBackgroundProcess(pid)
        guard isBg else { return false }

        let recKey = makeKeyWindowRecord(windowID: windowID, phaseByte: 1)
        let recAct = makeAppActivationRecord(windowID: windowID, eventType: 1)
        let recDeact = makeAppActivationRecord(windowID: windowID, eventType: 2)

        let r1 = recKey.withUnsafeBytes { ptr in postRec(&psn, ptr.baseAddress!) }
        guard r1 == 0 else { return false }
        _ = recAct.withUnsafeBytes { ptr in postRec(&psn, ptr.baseAddress!) }
        _ = recDeact.withUnsafeBytes { ptr in postRec(&psn, ptr.baseAddress!) }
        return true
    }

    /// Restaura el estado de la ventana en background tras `beginKeyWindowSpoof`.
    /// Equivalente a `0x10001ebc0` (`keyWindowSpoof(end)`) en `app-cu-helper`.
    static func endKeyWindowSpoof(pid: pid_t, windowID: CGWindowID) {
        guard windowID != 0, let postRec = fnPostEventRecordTo else { return }
        var (isBg, psn) = isBackgroundProcess(pid)
        guard isBg else { return }

        let recResign = makeKeyWindowRecord(windowID: windowID, phaseByte: 2)
        _ = recResign.withUnsafeBytes { ptr in postRec(&psn, ptr.baseAddress!) }
    }

    /// Ejecuta un bloque mientras la ventana `windowID` del proceso en background `pid`
    /// cree tener el foco de teclado (`keyWindowSpoof`), habilitando ítems del menú del
    /// Responder Chain (`Seleccionar todo`, `Copiar`, `Pegar`, `Deshacer`, etc.) y
    /// controles que requieren ventana clave sin robar el foco del usuario.
    static func withKeyWindowSpoof<T>(pid: pid_t, windowID: CGWindowID?, body: () throws -> T) rethrows -> T {
        guard let wid = windowID, wid != 0 else {
            return try body()
        }
        let spoofed = beginKeyWindowSpoof(pid: pid, windowID: wid)
        if spoofed {
            // Breve pausa (~12ms) para que el runloop de la app destino procese el evento
            usleep(12_000)
        }
        defer {
            if spoofed {
                endKeyWindowSpoof(pid: pid, windowID: wid)
            }
        }
        return try body()
    }
}
