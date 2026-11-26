import AppKit
import CoreGraphics

/// Mantém a Dock no monitor principal.
///
/// O macOS leva a Dock para qualquer monitor em cuja borda (a da posição da Dock)
/// o cursor encosta. Aqui o cursor nunca chega à última linha de pixels dessa borda
/// nos monitores secundários: quando chega, volta alguns pontos. Bordas encostadas
/// em outro monitor ficam livres, para o cursor poder passar de uma tela para a outra.
final class DockGuard {
    private enum Edge: String {
        case bottom, left, right
    }

    private static let edgeThreshold: CGFloat = 2
    private static let pushBack: CGFloat = 4
    private static let orientationRefresh: TimeInterval = 5

    private var edge: Edge = .bottom
    private var secondaryBounds: [CGRect] = []
    private var allBounds: [CGRect] = []
    private var monitor: Any?
    private var timer: Timer?

    func start() {
        refresh()
        moveDockToMainIfNeeded()

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let guardian = Unmanaged<DockGuard>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { guardian.refresh() }
        }, pointer)

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.handleMouseMoved()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.orientationRefresh, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        log("trava da Dock ativa (borda: \(edge.rawValue))")
    }

    private func refresh() {
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        edge = Edge(rawValue: orientation) ?? .bottom
        let main = CGMainDisplayID()
        let arranged = Displays.arranged()
        allBounds = arranged.map(CGDisplayBounds)
        secondaryBounds = arranged.filter { $0 != main }.map(CGDisplayBounds)
    }

    private func handleMouseMoved() {
        guard let point = CGEvent(source: nil)?.location else { return }
        for bounds in secondaryBounds {
            if let corrected = correction(for: point, on: bounds) {
                CGWarpMouseCursorPosition(corrected)
                CGAssociateMouseAndMouseCursorPosition(1)
                return
            }
        }
    }

    private func correction(for point: CGPoint, on bounds: CGRect) -> CGPoint? {
        switch edge {
        case .bottom:
            guard point.x >= bounds.minX, point.x < bounds.maxX,
                  point.y >= bounds.maxY - Self.edgeThreshold, point.y < bounds.maxY,
                  !isCovered(CGPoint(x: point.x, y: bounds.maxY + 1)) else { return nil }
            return CGPoint(x: point.x, y: bounds.maxY - Self.pushBack)
        case .left:
            guard point.y >= bounds.minY, point.y < bounds.maxY,
                  point.x >= bounds.minX, point.x < bounds.minX + Self.edgeThreshold,
                  !isCovered(CGPoint(x: bounds.minX - 1, y: point.y)) else { return nil }
            return CGPoint(x: bounds.minX + Self.pushBack, y: point.y)
        case .right:
            guard point.y >= bounds.minY, point.y < bounds.maxY,
                  point.x >= bounds.maxX - Self.edgeThreshold, point.x < bounds.maxX,
                  !isCovered(CGPoint(x: bounds.maxX + 1, y: point.y)) else { return nil }
            return CGPoint(x: bounds.maxX - Self.pushBack, y: point.y)
        }
    }

    private func isCovered(_ point: CGPoint) -> Bool {
        allBounds.contains { $0.contains(point) }
    }

    /// Se a Dock já estiver num monitor secundário, reinicia a Dock, que volta no principal.
    private func moveDockToMainIfNeeded() {
        guard let dockFrame = dockDisplayFrame() else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        guard !main.contains(CGPoint(x: dockFrame.midX, y: dockFrame.midY)) else { return }
        log("Dock fora do monitor principal: reiniciando a Dock")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    /// A Dock mantém uma janela do tamanho da tela onde está, na camada da Dock.
    private func dockDisplayFrame() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let dockWindow = windows.first {
            $0[kCGWindowOwnerName as String] as? String == "Dock" && $0[kCGWindowLayer as String] as? Int == dockLayer
        }
        guard let bounds = dockWindow?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}
