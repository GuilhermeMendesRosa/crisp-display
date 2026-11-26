import CoreGraphics
import Foundation

/// Mantém um monitor físico de baixa resolução espelhando uma tela virtual em HiDPI.
///
/// O macOS só oferece modos HiDPI (renderização em 2x) para monitores de alta resolução.
/// A tela virtual é criada com o dobro dos pixels do tamanho pedido (ex.: 1344x756 vira
/// 2688x1512) e o monitor físico passa a espelhá-la; a GPU reduz a imagem para a
/// resolução nativa do painel, deixando texto e interface nítidos.
///
/// Se o processo morrer, a tela virtual some e o macOS desfaz o espelhamento sozinho.
final class HiDPIMirror {
    private static let vendorID: UInt32 = 0xCD15
    private static let reconcileDelay: TimeInterval = 1.0
    private static let extraSizes = ["1280x720", "1344x756", "1440x810", "1600x900", "1920x1080"].compactMap(Size.init)

    private let target: DisplayMatch
    private let looksLike: Size
    private var virtualDisplay: CGVirtualDisplay?
    private var pendingReconcile: DispatchWorkItem?

    init(target: DisplayMatch, looksLike: Size) {
        self.target = target
        self.looksLike = looksLike
    }

    func start() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, _, context in
            guard let context else { return }
            Unmanaged<HiDPIMirror>.fromOpaque(context).takeUnretainedValue().scheduleReconcile()
        }, pointer)
        reconcile()
    }

    func stop() {
        guard virtualDisplay != nil else { return }
        log("encerrando: removendo a tela virtual")
        virtualDisplay = nil
    }

    private func scheduleReconcile() {
        pendingReconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconcileDelay, execute: work)
    }

    private func reconcile() {
        guard let physical = findPhysical() else {
            if virtualDisplay != nil {
                log("monitor \(target) desconectado: removendo a tela virtual")
                virtualDisplay = nil
            }
            return
        }

        guard let virtualDisplay else {
            createVirtualDisplay(for: physical)
            scheduleReconcile()
            return
        }

        let virtualID = virtualDisplay.displayID
        guard CGDisplayIsOnline(virtualID) != 0 else {
            scheduleReconcile()
            return
        }
        if CGDisplayMirrorsDisplay(physical) != virtualID {
            mirror(physical, onto: virtualID)
        }
    }

    private func findPhysical() -> CGDirectDisplayID? {
        let virtualID = virtualDisplay?.displayID
        return Displays.online().first { $0 != virtualID && target.matches($0) }
    }

    private func createVirtualDisplay(for physical: CGDirectDisplayID) {
        let sizes = modeSizes()
        let largest = sizes.max { $0.width * $0.height < $1.width * $1.height } ?? looksLike

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "\(Displays.name(of: physical)) HiDPI"
        descriptor.vendorID = Self.vendorID
        descriptor.productID = target.model & 0xFFFF
        descriptor.serialNum = target.vendor
        descriptor.maxPixelsWide = UInt32(largest.width * 2)
        descriptor.maxPixelsHigh = UInt32(largest.height * 2)
        descriptor.sizeInMillimeters = CGDisplayScreenSize(physical)
        descriptor.terminationHandler = { _, _ in log("o macOS encerrou a tela virtual") }

        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = sizes.map {
            CGVirtualDisplayMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: refreshRate(of: physical))
        }
        guard display.apply(settings) else {
            log("erro: o macOS recusou as configurações da tela virtual")
            return
        }
        virtualDisplay = display
        log("tela virtual \(display.displayID) criada para o monitor \(physical) (\(looksLike) HiDPI)")
    }

    /// O tamanho pedido primeiro (vira o padrão) e depois outros da mesma proporção,
    /// para dar opções em Ajustes do Sistema > Monitores.
    private func modeSizes() -> [Size] {
        let ratio = Double(looksLike.width) / Double(looksLike.height)
        let extras = Self.extraSizes.filter {
            abs(Double($0.width) / Double($0.height) - ratio) < 0.01 && $0.width != looksLike.width
        }
        return [looksLike] + extras
    }

    private func refreshRate(of display: CGDirectDisplayID) -> Double {
        let rate = CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
        return rate > 0 ? rate : 60
    }

    private func mirror(_ physical: CGDirectDisplayID, onto virtualID: CGDirectDisplayID) {
        applyRequestedMode(to: virtualID)
        let origin = CGDisplayBounds(physical).origin

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, virtualID, Int32(origin.x), Int32(origin.y))
        CGConfigureDisplayMirrorOfDisplay(config, physical, virtualID)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result == .success {
            log("monitor \(physical) espelhando a tela virtual \(virtualID)")
        } else {
            log("erro ao espelhar (CGError \(result.rawValue)), tentando de novo")
            scheduleReconcile()
        }
    }

    private func applyRequestedMode(to virtualID: CGDirectDisplayID) {
        let modes = CGDisplayCopyAllDisplayModes(virtualID, nil) as? [CGDisplayMode] ?? []
        let hiDPI = modes.first {
            $0.width == looksLike.width && $0.height == looksLike.height && $0.pixelWidth == looksLike.width * 2
        }
        guard let hiDPI, CGDisplayCopyDisplayMode(virtualID)?.ioDisplayModeID != hiDPI.ioDisplayModeID else { return }
        CGDisplaySetDisplayMode(virtualID, hiDPI, nil)
    }
}
