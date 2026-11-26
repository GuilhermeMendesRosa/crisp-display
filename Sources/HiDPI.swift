import CoreGraphics
import Foundation

/// Deixa um monitor físico de baixa resolução em HiDPI (interface desenhada em 2x e
/// reduzida para o painel), com texto e interface nítidos.
///
/// Dois caminhos, nesta ordem:
/// - Modo próprio: se o monitor já oferece o modo HiDPI pedido (ex.: 1344x756 com
///   2688x1512 pixels), ele é aplicado direto. Sem tela virtual e sem espelhamento, o
///   cursor passa entre os monitores sem travar.
/// - Tela virtual: senão, uma tela virtual com o dobro dos pixels é criada e o monitor
///   físico passa a espelhá-la. Se o processo morrer, a tela virtual some e o macOS
///   desfaz o espelhamento sozinho.
final class HiDPI {
    private static let vendorID: UInt32 = 0xCD15
    private static let reconcileDelay: TimeInterval = 1.0
    private static let extraSizes = ["1280x720", "1344x756", "1440x810", "1600x900", "1920x1080"].compactMap(Size.init)
    private static let allModesOptions = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary

    private let target: DisplayMatch
    private let looksLike: Size
    private let placement: Placement?
    private var virtualDisplay: CGVirtualDisplay?
    private var pendingReconcile: DispatchWorkItem?
    /// Monitor em que o modo próprio já foi aplicado nesta conexão. Depois disso, trocas
    /// feitas em Ajustes do Sistema são respeitadas até o monitor reconectar.
    private var nativeApplied: CGDirectDisplayID?
    private var nativeFailed = false

    init(target: DisplayMatch, looksLike: Size, placement: Placement?) {
        self.target = target
        self.looksLike = looksLike
        self.placement = placement
    }

    func start() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, _, context in
            guard let context else { return }
            Unmanaged<HiDPI>.fromOpaque(context).takeUnretainedValue().scheduleReconcile()
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
            nativeApplied = nil
            nativeFailed = false
            return
        }

        if virtualDisplay == nil, !nativeFailed, let mode = nativeMode(of: physical) {
            if nativeApplied != physical {
                applyNative(mode, to: physical)
            }
            if let placement {
                keepAttached(physical, placement)
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
            return
        }
        if let placement {
            keepAttached(virtualID, placement)
        }
    }

    private func findPhysical() -> CGDirectDisplayID? {
        let virtualID = virtualDisplay?.displayID
        return Displays.online().first { $0 != virtualID && target.matches($0) }
    }

    /// Recoloca o monitor encostado no principal quando o macOS o põe em outro lugar
    /// (ex.: ao reconectar o principal). Deslocamentos ao longo da borda, feitos em
    /// Ajustes do Sistema, são mantidos.
    private func keepAttached(_ display: CGDirectDisplayID, _ placement: Placement) {
        let main = CGMainDisplayID()
        guard display != main else { return }
        let mainBounds = CGDisplayBounds(main)
        let bounds = CGDisplayBounds(display)
        guard !placement.isAttached(bounds, to: mainBounds) else { return }

        let origin = placement.centeredOrigin(for: bounds.size, beside: mainBounds)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, display, Int32(origin.x), Int32(origin.y))
        if CGCompleteDisplayConfiguration(config, .permanently) == .success {
            log("monitor recolocado: \(placement.rawValue) do monitor principal")
        }
    }

    // MARK: - Modo próprio do monitor

    private func nativeMode(of physical: CGDirectDisplayID) -> CGDisplayMode? {
        let modes = CGDisplayCopyAllDisplayModes(physical, Self.allModesOptions) as? [CGDisplayMode] ?? []
        return modes.first { isRequestedHiDPI($0) && $0.isUsableForDesktopGUI() }
    }

    private func applyNative(_ mode: CGDisplayMode, to physical: CGDirectDisplayID) {
        nativeApplied = physical
        if let current = CGDisplayCopyDisplayMode(physical), isRequestedHiDPI(current) {
            log("monitor \(physical) já está em \(looksLike) HiDPI (modo do próprio monitor)")
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, physical, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result == .success {
            log("monitor \(physical) em \(looksLike) HiDPI (modo do próprio monitor)")
        } else {
            log("erro ao aplicar o modo do monitor (CGError \(result.rawValue)): usando tela virtual")
            nativeFailed = true
            scheduleReconcile()
        }
    }

    private func isRequestedHiDPI(_ mode: CGDisplayMode) -> Bool {
        mode.width == looksLike.width && mode.height == looksLike.height && mode.pixelWidth == looksLike.width * 2
    }

    // MARK: - Tela virtual

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

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, physical, virtualID)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result == .success {
            log("monitor \(physical) espelhando a tela virtual \(virtualID)")
        } else {
            log("erro ao espelhar (CGError \(result.rawValue)), tentando de novo")
        }
        scheduleReconcile()
    }

    private func applyRequestedMode(to virtualID: CGDirectDisplayID) {
        let modes = CGDisplayCopyAllDisplayModes(virtualID, nil) as? [CGDisplayMode] ?? []
        guard let hiDPI = modes.first(where: isRequestedHiDPI),
              CGDisplayCopyDisplayMode(virtualID)?.ioDisplayModeID != hiDPI.ioDisplayModeID else { return }
        CGDisplaySetDisplayMode(virtualID, hiDPI, nil)
    }
}
