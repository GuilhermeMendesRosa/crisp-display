import AppKit
import ApplicationServices
import CoreGraphics

/// Mantém a Dock no monitor principal e deixa o cursor passar sem travar para o
/// monitor que fica do outro lado da borda da Dock.
///
/// - Trava: o macOS leva a Dock para qualquer monitor em cuja borda (a da posição da
///   Dock) o cursor encosta. Aqui o cursor nunca chega à última linha de pixels dessa
///   borda nos monitores secundários.
/// - Passagem: o macOS segura o cursor por um instante na borda onde está a Dock, para
///   facilitar acertá-la. Se houver um monitor do outro lado e o cursor estiver indo
///   para ele, passa direto.
///
/// Com permissão de Acessibilidade, um event tap corrige a posição antes de o macOS
/// aplicar o movimento (técnica do DockPin, MIT). Sem ela, um monitor global de eventos
/// corrige depois, movendo o cursor: funciona, mas pode dar pequenas travadas.
final class DockGuard {
    private enum Edge: String {
        case bottom, left, right
    }

    private enum Mode: String {
        case tap = "interceptando eventos"
        case reactive = "reativo, sem permissão de Acessibilidade"
    }

    private static let edgeThreshold: CGFloat = 2
    private static let pushBack: CGFloat = 3
    private static let healthCheckInterval: TimeInterval = 0.5
    private static let orientationRefresh: TimeInterval = 5

    private var edge: Edge = .bottom
    private var mainBounds: CGRect = .null
    private var secondaryBounds: [CGRect] = []
    private var allBounds: [CGRect] = []
    private var mode: Mode?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var lastOrientationRefresh = Date.distantPast
    /// Uma tentativa por arranjo de monitores, para não ficar piscando a Dock se o
    /// macOS insistir na reserva.
    private var staleAreaFixTried = false

    func start() {
        refresh()
        warnIfDockOutsideMain()

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let guardian = Unmanaged<DockGuard>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                guardian.staleAreaFixTried = false
                guardian.refresh()
            }
        }, pointer)

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        selectMode()

        let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Modo

    /// Um tap ativo num processo que perdeu a permissão de Acessibilidade pode travar o
    /// mouse da sessão inteira, então a permissão é conferida a cada meio segundo.
    private func healthCheck() {
        selectMode()
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        if Date().timeIntervalSince(lastOrientationRefresh) > Self.orientationRefresh {
            refresh()
            fixStaleDockArea()
        }
    }

    private func selectMode() {
        let wanted: Mode = AXIsProcessTrusted() ? .tap : .reactive
        guard wanted != mode else { return }

        removeTap()
        removeGlobalMonitor()
        let installed = wanted == .tap ? installTap() : installGlobalMonitor()
        mode = installed ? wanted : nil
        if let mode {
            log("trava da Dock ativa (borda: \(edge.rawValue), modo: \(mode.rawValue))")
        }
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let guardian = Unmanaged<DockGuard>.fromOpaque(context).takeUnretainedValue()
                return guardian.handleTapped(event, type: type)
            },
            userInfo: pointer
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapSource = source
        return true
    }

    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        eventTap = nil
        tapSource = nil
    }

    private func installGlobalMonitor() -> Bool {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.handleObserved(event)
        }
        return globalMonitor != nil
    }

    private func removeGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
    }

    // MARK: - Eventos

    private func handleTapped(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if AXIsProcessTrusted(), let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let delta = CGVector(
            dx: event.getDoubleValueField(.mouseEventDeltaX),
            dy: event.getDoubleValueField(.mouseEventDeltaY)
        )
        if let corrected = correctedPosition(for: event.location, movingBy: delta) {
            event.location = corrected
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleObserved(_ event: NSEvent) {
        guard let point = CGEvent(source: nil)?.location else { return }
        let delta = CGVector(dx: event.deltaX, dy: event.deltaY)
        guard let corrected = correctedPosition(for: point, movingBy: delta) else { return }
        CGWarpMouseCursorPosition(corrected)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func correctedPosition(for point: CGPoint, movingBy delta: CGVector) -> CGPoint? {
        if let crossed = passThrough(from: point, movingBy: delta) {
            return crossed
        }
        for bounds in secondaryBounds {
            if let corrected = keptOffEdge(point, on: bounds) {
                return corrected
            }
        }
        return nil
    }

    // MARK: - Geometria (coordenadas globais do Quartz: origem no canto superior esquerdo)

    private func refresh() {
        lastOrientationRefresh = Date()
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        edge = Edge(rawValue: orientation) ?? .bottom
        let main = CGMainDisplayID()
        let arranged = Displays.arranged()
        allBounds = arranged.map(CGDisplayBounds)
        mainBounds = CGDisplayBounds(main)
        secondaryBounds = arranged.filter { $0 != main }.map(CGDisplayBounds)
    }

    private func passThrough(from point: CGPoint, movingBy delta: CGVector) -> CGPoint? {
        let main = mainBounds
        guard !main.isNull else { return nil }
        let target: CGPoint
        switch edge {
        case .bottom:
            guard delta.dy > 0, point.x >= main.minX, point.x < main.maxX,
                  point.y >= main.maxY - Self.edgeThreshold, point.y < main.maxY else { return nil }
            target = CGPoint(x: point.x, y: main.maxY + 1)
        case .left:
            guard delta.dx < 0, point.y >= main.minY, point.y < main.maxY,
                  point.x >= main.minX, point.x < main.minX + Self.edgeThreshold else { return nil }
            target = CGPoint(x: main.minX - 1, y: point.y)
        case .right:
            guard delta.dx > 0, point.y >= main.minY, point.y < main.maxY,
                  point.x >= main.maxX - Self.edgeThreshold, point.x < main.maxX else { return nil }
            target = CGPoint(x: main.maxX + 1, y: point.y)
        }
        return isCovered(target) ? target : nil
    }

    private func keptOffEdge(_ point: CGPoint, on bounds: CGRect) -> CGPoint? {
        switch edge {
        case .bottom:
            guard point.x >= bounds.minX, point.x < bounds.maxX,
                  point.y >= bounds.maxY - Self.edgeThreshold, point.y < bounds.maxY + Self.edgeThreshold,
                  !isCovered(CGPoint(x: point.x, y: bounds.maxY + 1)) else { return nil }
            return CGPoint(x: point.x, y: bounds.maxY - Self.pushBack)
        case .left:
            guard point.y >= bounds.minY, point.y < bounds.maxY,
                  point.x > bounds.minX - Self.edgeThreshold, point.x < bounds.minX + Self.edgeThreshold,
                  !isCovered(CGPoint(x: bounds.minX - 1, y: point.y)) else { return nil }
            return CGPoint(x: bounds.minX + Self.pushBack, y: point.y)
        case .right:
            guard point.y >= bounds.minY, point.y < bounds.maxY,
                  point.x >= bounds.maxX - Self.edgeThreshold, point.x < bounds.maxX + Self.edgeThreshold,
                  !isCovered(CGPoint(x: bounds.maxX + 1, y: point.y)) else { return nil }
            return CGPoint(x: bounds.maxX - Self.pushBack, y: point.y)
        }
    }

    private func isCovered(_ point: CGPoint) -> Bool {
        allBounds.contains { $0.contains(point) }
    }

    // MARK: - Posição atual da Dock

    /// A Dock só troca de monitor com movimento real do mouse: reiniciar a Dock ou
    /// simular eventos não adianta. Se ela já estiver num secundário, só avisa.
    private func warnIfDockOutsideMain() {
        guard let dockFrame = dockDisplayFrame() else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        guard !main.contains(CGPoint(x: dockFrame.midX, y: dockFrame.midY)) else { return }
        log("a Dock está fora do monitor principal: empurre o mouse contra a borda de baixo do principal, num trecho sem outro monitor embaixo")
    }

    /// Quando a Dock volta para o principal, o macOS às vezes continua reservando o espaço
    /// dela no secundário, e janelas maximizadas ou centralizadas lá deixam uma faixa
    /// vazia. Ligar e desligar o "ocultar Dock" faz o macOS recalcular a reserva. Pede a
    /// permissão de Automação (controlar o System Events) na primeira vez.
    private func fixStaleDockArea() {
        guard !staleAreaFixTried,
              UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") == false,
              let dockFrame = dockDisplayFrame(),
              mainBounds.contains(CGPoint(x: dockFrame.midX, y: dockFrame.midY)),
              NSScreen.screens.contains(where: reservesDockArea) else { return }
        staleAreaFixTried = true
        log("o macOS ainda reserva o espaço da Dock num monitor secundário: atualizando a Dock")
        DispatchQueue.global().async {
            for hidden in ["true", "false"] {
                let script = "tell application \"System Events\" to set autohide of dock preferences to \(hidden)"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    log("não deu para atualizar a Dock: libere o crisp-display em Ajustes do Sistema > Privacidade e Segurança > Automação")
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// Coordenadas do Cocoa aqui (origem no canto inferior esquerdo).
    private func reservesDockArea(_ screen: NSScreen) -> Bool {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard id != CGMainDisplayID() else { return false }
        let frame = screen.frame
        let visible = screen.visibleFrame
        switch edge {
        case .bottom: return visible.minY - frame.minY > 1
        case .left: return visible.minX - frame.minX > 1
        case .right: return frame.maxX - visible.maxX > 1
        }
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
