import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

struct WinInfo {
    let id: CGWindowID
    var title: String
    let bounds: CGRect  // puntos de pantalla, origen arriba a la izquierda
    let onScreen: Bool
}

private func winInfo(_ w: JSON) -> (info: WinInfo, pid: pid_t, layer: Int, alpha: Double)? {
    guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let b = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b)
    else { return nil }
    let info = WinInfo(
        id: id, title: w[kCGWindowName as String] as? String ?? "", bounds: rect,
        onScreen: (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    return (
        info, (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
        (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    )
}

/// Ventanas normales (capa 0) de un proceso, de adelante hacia atrás. Con `all`, también las
/// minimizadas o de otro escritorio (cuesta una consulta más al servidor gráfico).
/// Se descartan las auxiliares diminutas o invisibles que muchas apps mantienen.
func cgWindows(pid: pid_t, all: Bool = false) -> [WinInfo] {
    func read(_ opts: CGWindowListOption) -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [JSON] else { return [] }
        return list.compactMap { w in
            guard let r = winInfo(w), r.pid == pid, r.layer == 0, r.alpha > 0, r.info.bounds.width >= 100, r.info.bounds.height >= 50 else { return nil }
            return r.info
        }
    }
    let front = read([.optionOnScreenOnly, .excludeDesktopElements])
    guard all else { return front }
    let seen = Set(front.map(\.id))
    return front + read([.optionAll, .excludeDesktopElements]).filter { !seen.contains($0.id) }
}

/// Estado actual de una ventana concreta; nil si ya no existe o no es de ese proceso.
func cgWindow(id: CGWindowID, pid: pid_t) -> WinInfo? {
    var ptr: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
    guard let ids = CFArrayCreate(nil, &ptr, 1, nil), let list = CGWindowListCreateDescriptionFromArray(ids) as? [JSON],
        let w = list.first, let r = winInfo(w), r.pid == pid
    else { return nil }
    return r.info
}

struct CaptureError: Error { let message: String }

/// Captura de una sola ventana con ScreenCaptureKit (sirve aunque esté tapada por otras).
final class Capturer {
    private var cache: [CGWindowID: SCWindow] = [:]
    private let lock = NSLock()

    private func refresh() throws {
        let sem = DispatchSemaphore(value: 0)
        var found: [SCWindow] = []
        var failure: Error?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            found = content?.windows ?? []
            failure = error
            sem.signal()
        }
        if sem.wait(timeout: .now() + 3) == .timedOut { throw CaptureError(message: "ScreenCaptureKit window list did not answer in 3 s") }
        if let failure { throw CaptureError(message: failure.localizedDescription) }
        lock.lock()
        cache = Dictionary(found.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
    }

    private func window(_ id: CGWindowID, forceRefresh: Bool) throws -> SCWindow {
        lock.lock()
        let hit = cache[id]
        lock.unlock()
        if let hit, !forceRefresh { return hit }
        try refresh()
        lock.lock()
        defer { lock.unlock() }
        guard let w = cache[id] else { throw CaptureError(message: "window \(id) is not capturable (closed?)") }
        return w
    }

    /// Deja lista la lista de ventanas para que el primer screenshot no pague esa consulta.
    func prewarm() {
        DispatchQueue.global(qos: .utility).async { try? self.refresh() }
    }

    /// Píxeles por punto de la pantalla donde está la ventana.
    func density(_ id: CGWindowID) -> CGFloat {
        guard let w = try? window(id, forceRefresh: false) else { return 2 }
        return CGFloat(SCContentFilter(desktopIndependentWindow: w).pointPixelScale)
    }

    func capture(_ id: CGWindowID, pixelWidth: Int, pixelHeight: Int) throws -> CGImage {
        var last = CaptureError(message: "capture failed")
        for attempt in 0..<2 {
            let w = try window(id, forceRefresh: attempt == 1)
            let cfg = SCStreamConfiguration()
            cfg.width = max(pixelWidth, 16)
            cfg.height = max(pixelHeight, 16)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            let sem = DispatchSemaphore(value: 0)
            var image: CGImage?
            var failure: Error?
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) { img, error in
                image = img
                failure = error
                sem.signal()
            }
            if sem.wait(timeout: .now() + 3) == .timedOut { throw CaptureError(message: "ScreenCaptureKit capture did not answer in 3 s") }
            if let image { return image }
            last = CaptureError(message: failure?.localizedDescription ?? "capture failed")
        }
        throw last
    }
}

func encodeImage(_ image: CGImage, jpegQuality: Double?) -> JSON? {
    let data = NSMutableData()
    let type = jpegQuality == nil ? "public.png" : "public.jpeg"
    guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
    let props = jpegQuality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
    CGImageDestinationAddImage(dest, image, props)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return [
        "type": "image", "data": (data as Data).base64EncodedString(),
        "mimeType": jpegQuality == nil ? "image/png" : "image/jpeg",
    ]
}
