import AppKit
import QuartzCore

// MARK: - PhantomCursor (equivalente a _TtC16ComputerUseSwift13PhantomCursor en Claude Desktop)
//
// Dibuja un cursor virtual flotante con animación suave de desplazamiento ("glide"),
// micro-pulsación de clic ("press"), onda expansiva ("pulse") y persistencia inteligente
// entre turnos para que el usuario vea al agente moverse de un elemento a otro
// de forma natural sin mover el ratón físico ni robar el foco del sistema.

final class PhantomCursor {
    static let shared = PhantomCursor()

    private let windowSize: CGFloat = 64
    private let hotspotOffset: CGFloat = 32  // La punta de la flecha está en el centro (32, 32)
    private var window: NSWindow?
    private var arrowLayer: CAShapeLayer?
    private var badgeLayer: CATextLayer?
    private var idleWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var isInitialized = false

    /// Última posición en pantalla (coordenadas CoreGraphics, origen superior izquierdo)
    private var lastScreenPoint: CGPoint?
    private let stateLock = NSLock()

    private init() {}

    /// Inicializa AppKit en modo `.accessory` en el hilo principal (sin Dock ni barra de menú).
    func setupOnMainThread() {
        if Thread.isMainThread {
            ensureApp()
        } else {
            DispatchQueue.main.async { self.ensureApp() }
        }
    }

    private func ensureApp() {
        guard !isInitialized else { return }
        isInitialized = true
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
    }

    /// Desplaza el cursor virtual suavemente hacia `screenPoint`.
    /// Devuelve el tiempo estimado del desplazamiento en milisegundos para sincronizar la acción.
    @discardableResult
    func show(at screenPoint: CGPoint, windowID: CGWindowID? = nil, pulse: Bool = true, label: String? = nil) -> Int {
        stateLock.lock()
        let prev = lastScreenPoint
        lastScreenPoint = screenPoint
        stateLock.unlock()

        let dist: Double
        if let prev {
            dist = hypot(Double(screenPoint.x - prev.x), Double(screenPoint.y - prev.y))
        } else {
            dist = 140.0
        }

        let durationMs: Int
        if dist < 10 {
            durationMs = 40
        } else {
            let dur = min(0.42, max(0.20, dist / 1600.0))
            durationMs = Int(dur * 1000)
        }

        DispatchQueue.main.async {
            self.presentOnMain(
                screenPoint: screenPoint,
                prevPoint: prev,
                duration: Double(durationMs) / 1000.0,
                pulse: pulse,
                label: label
            )
        }
        return durationMs
    }

    /// Oculta inmediatamente el cursor fantasma.
    func hide() {
        DispatchQueue.main.async {
            self.idleWorkItem?.cancel()
            self.hideWorkItem?.cancel()
            self.window?.orderOut(nil)
        }
    }

    /// Desvanece y oculta el cursor al terminar la tarea (lo invoca la herramienta `hide_cursor`).
    func dismiss() {
        DispatchQueue.main.async {
            self.idleWorkItem?.cancel()
            self.hideWorkItem?.cancel()
            guard let w = self.window, w.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                w.animator().alphaValue = 0.0
            }, completionHandler: {
                w.orderOut(nil)
                w.alphaValue = 1.0
            })
        }
    }

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }
        if NSApp == nil {
            _ = NSApplication.shared
        }
        // `.accessory` permite mostrar NSWindows borderless sin aparecer en el Dock ni robar foco.
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.accessory)
        }

        let rect = NSRect(x: 0, y: 0, width: windowSize, height: windowSize)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: rect)
        content.wantsLayer = true
        content.layer?.masksToBounds = false
        w.contentView = content

        // Flecha del cursor (la punta coincide con (hotspotOffset, hotspotOffset) en coordenadas de vista)
        let arrow = CAShapeLayer()
        arrow.frame = rect
        let path = CGMutablePath()
        let cx = hotspotOffset
        let cy = hotspotOffset
        // Polígono de flecha estilo macOS (en coordenadas de capa AppKit: Y crece hacia arriba)
        path.move(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx, y: cy - 20))
        path.addLine(to: CGPoint(x: cx + 4.8, y: cy - 15.5))
        path.addLine(to: CGPoint(x: cx + 8.2, y: cy - 23.0))
        path.addLine(to: CGPoint(x: cx + 11.2, y: cy - 21.5))
        path.addLine(to: CGPoint(x: cx + 7.8, y: cy - 14.0))
        path.addLine(to: CGPoint(x: cx + 14.0, y: cy - 14.0))
        path.closeSubpath()

        arrow.path = path
        // Relleno violeta/azul brillante con borde blanco para distinguirlo del cursor del usuario
        arrow.fillColor = NSColor(calibratedRed: 0.38, green: 0.44, blue: 0.98, alpha: 0.96).cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 2.4
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.52
        arrow.shadowRadius = 4.0
        arrow.shadowOffset = CGSize(width: 0, height: -1.5)

        content.layer?.addSublayer(arrow)
        self.arrowLayer = arrow
        self.window = w
        return w
    }

    private func presentOnMain(screenPoint: CGPoint, prevPoint: CGPoint?, duration: Double, pulse: Bool, label: String?) {
        let w = ensureWindow()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let targetOrigin = NSPoint(
            x: screenPoint.x - hotspotOffset,
            y: primaryHeight - screenPoint.y - hotspotOffset
        )
        let targetFrame = NSRect(origin: targetOrigin, size: NSSize(width: windowSize, height: windowSize))

        // Cancelar temporizadores anteriores de inactividad
        idleWorkItem?.cancel()
        hideWorkItem?.cancel()

        let wasVisible = w.isVisible

        if !wasVisible {
            // Si estaba oculto pero tenemos una posición previa, arrancamos desde ella con opacidad 0
            let startPt = prevPoint ?? CGPoint(x: screenPoint.x - 40, y: screenPoint.y + 40)
            let startOrigin = NSPoint(
                x: startPt.x - hotspotOffset,
                y: primaryHeight - startPt.y - hotspotOffset
            )
            w.setFrame(NSRect(origin: startOrigin, size: NSSize(width: windowSize, height: windowSize)), display: false)
            w.alphaValue = 0.0
            w.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            // Curva suave natural (aceleración rápida, frenado sedoso en el punto de llegada)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            w.animator().setFrame(targetFrame, display: true)
            w.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            guard let self, self.window != nil else { return }
            if pulse {
                self.triggerClickFeedback()
            }
            self.scheduleIdleTimers()
        }
    }

    private func triggerClickFeedback() {
        guard let w = window, let rootLayer = w.contentView?.layer else { return }

        // Micro-animación de pulsación física de la flecha
        if let arrow = arrowLayer {
            let press = CAKeyframeAnimation(keyPath: "transform.scale")
            press.values = [1.0, 0.88, 1.0]
            press.keyTimes = [0.0, 0.38, 1.0]
            press.duration = 0.22
            press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arrow.add(press, forKey: "clickBounce")
        }

        // Onda expansiva debajo de la flecha
        let ring = CAShapeLayer()
        let r: CGFloat = 19
        ring.frame = CGRect(x: hotspotOffset - r, y: hotspotOffset - r, width: r * 2, height: r * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = NSColor(calibratedRed: 0.38, green: 0.44, blue: 0.98, alpha: 0.25).cgColor
        ring.strokeColor = NSColor(calibratedRed: 0.48, green: 0.55, blue: 1.0, alpha: 0.92).cgColor
        ring.lineWidth = 2.5

        if let arrow = arrowLayer {
            rootLayer.insertSublayer(ring, below: arrow)
        } else {
            rootLayer.addSublayer(ring)
        }

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.35
        scaleAnim.toValue = 1.55

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = 0.34
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            ring.removeFromSuperlayer()
        }
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    /// El cursor permanece visible durante toda la tarea y solo se oculta con `hide_cursor`.
    /// Como red de seguridad opcional, `phantom_cursor_idle_ms` en config.json permite un
    /// auto-ocultado por inactividad (> 0). Con el valor por defecto (0) nunca se oculta solo.
    private func scheduleIdleTimers() {
        idleWorkItem?.cancel()
        hideWorkItem?.cancel()

        let fallbackMs = ConfigStore.shared.load().phantomCursorIdleMs
        guard fallbackMs > 0 else { return }

        let hideItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        self.hideWorkItem = hideItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(fallbackMs) / 1000.0, execute: hideItem)
    }
}
